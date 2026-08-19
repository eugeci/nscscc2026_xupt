/* SPDX-License-Identifier: GPL-2.0 */
#include "xnpu.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <unistd.h>

struct fixture {
	const char *name;
	const char *input_path;
	uint32_t checksum;
	uint8_t expected[10];
	size_t expected_size;
	uint32_t top1;
};

static const struct fixture facenet_seed42 = {
	"facenet_seed42",
	"/fixtures/facenet_seed42.bin",
	0x685184b3U,
	{ 58, 132, 81, 104, 137 },
	5,
	0,
};

static const struct fixture facenet_seed7 = {
	"facenet_seed7",
	"/fixtures/facenet_seed7.bin",
	0x5d5d7d3dU,
	{ 70, 125, 93, 93, 123 },
	5,
	0,
};

static const struct fixture mnist_lenet_7 = {
	"mnist_lenet_7",
	"/fixtures/mnist_lenet_7.bin",
	0xe5330809U,
	{ 9, 8, 51, 0, 0, 0, 0, 229, 0, 0 },
	10,
	7,
};

static const struct fixture npu_vgg_s1_demo = {
	"npu_vgg_s1_demo",
	"/fixtures/npu_vgg_s1_demo.bin",
	0x070006ebU,
	{ 168, 6, 0, 7, 0, 0, 0, 0, 67, 0 },
	10,
	0,
};

static const struct fixture npu_vgg_s2b_demo = {
	"npu_vgg_s2b_demo",
	"/fixtures/npu_vgg_s2b_demo.bin",
	0x00460f09U,
	{ 0, 0, 72, 0, 9, 12, 14, 0, 0, 3 },
	10,
	2,
};

static unsigned int completed_items;
static unsigned int golden_failures;

static void finish_forever(void)
{
	for (;;)
		sleep(3600);
}

static void fail(const char *operation, int result)
{
	printf("XNPU_STAGE5_FAIL operation=%s error=%d (%s)\n",
	       operation, -result, strerror(-result));
	fflush(stdout);
	finish_forever();
}

static void expect_result(const char *operation, int result, int expected)
{
	if (result != expected)
		fail(operation, result ? result : -EIO);
}

static void put_le32(uint8_t *data, uint32_t value)
{
	data[0] = (uint8_t)value;
	data[1] = (uint8_t)(value >> 8);
	data[2] = (uint8_t)(value >> 16);
	data[3] = (uint8_t)(value >> 24);
}

static void package_error_tests(void)
{
	const struct xnpu_section *parameters;
	struct xnpu_package valid;
	struct xnpu_package rejected;
	uint8_t *data;
	uint8_t *copy;
	size_t size;
	size_t parameter_offset;
	int result;

	result = xnpu_read_file("/models/facenet_lbp_v1.xnpu", &data, &size);
	if (result)
		fail("error_package_read", result);
	result = xnpu_package_init(&valid, data, size);
	if (result)
		fail("error_package_reference", result);
	parameters = xnpu_package_section(&valid, XNPU_SECTION_PARAMETERS);
	if (!parameters)
		fail("error_package_parameters", -EPROTO);
	parameter_offset = (size_t)(parameters->data - data);
	copy = malloc(size);
	if (!copy)
		fail("error_package_alloc", -ENOMEM);

	memcpy(copy, data, size);
	copy[0] ^= 1;
	result = xnpu_package_init(&rejected, copy, size);
	expect_result("bad_magic_not_rejected", result, -EPROTO);
	printf("XNPU_STAGE5_ERROR_PASS kind=bad_magic error=%d\n", -result);

	memcpy(copy, data, size);
	copy[112] ^= 1;
	result = xnpu_package_init(&rejected, copy, size);
	expect_result("bad_sha_not_rejected", result, -EBADMSG);
	printf("XNPU_STAGE5_ERROR_PASS kind=bad_sha256 error=%d\n", -result);

	memcpy(copy, data, size);
	copy[parameter_offset] ^= 1;
	result = xnpu_package_init(&rejected, copy, size);
	expect_result("bad_crc_not_rejected", result, -EBADMSG);
	printf("XNPU_STAGE5_ERROR_PASS kind=bad_section_crc error=%d\n",
	       -result);

	memcpy(copy, data, size);
	put_le32(copy + 256 + 12, UINT32_MAX);
	result = xnpu_package_init(&rejected, copy, size);
	expect_result("oversize_section_not_rejected", result, -EPROTO);
	printf("XNPU_STAGE5_ERROR_PASS kind=oversize_section error=%d\n",
	       -result);

	free(copy);
	free(data);
}

static void fill_model_request(const struct xnpu_package *package,
			       struct xnpu_model *model,
			       const void *descriptors)
{
	const struct xnpu_section *parameters =
		xnpu_package_section(package, XNPU_SECTION_PARAMETERS);

	memset(model, 0, sizeof(*model));
	model->layer_count = package->info.layer_count;
	model->input_mode = package->info.input_mode;
	model->input_bytes = package->info.input.bytes;
	model->parameter_bytes = package->info.parameter_bytes;
	model->scratch_bytes = package->info.scratch_bytes;
	model->result_bytes = package->info.output.bytes;
	model->result_width = package->info.output.width;
	model->result_height = package->info.output.height;
	model->result_channels = package->info.output.channels;
	model->result_layout = package->info.output.layout;
	model->result_dtype = package->info.output.dtype;
	model->descriptors = (uint64_t)(uintptr_t)descriptors;
	model->parameters = (uint64_t)(uintptr_t)parameters->data;
}

static void expect_ioctl_error(int fd, unsigned long request, void *argument,
			       int expected_errno, const char *operation)
{
	int result;

	errno = 0;
	result = ioctl(fd, request, argument);
	if (result != -1 || errno != expected_errno)
		fail(operation, result == -1 ? -errno : -EIO);
}

static void verify_model_boundary(struct xnpu_device *device)
{
	struct xnpu_run run;
	uint8_t byte;

	errno = 0;
	if (read(device->fd, &byte, sizeof(byte)) != -1 || errno != ENODATA)
		fail("stale_result_after_model_load", errno ? -errno : -EIO);
	memset(&run, 0, sizeof(run));
	run.flags = XNPU_RUN_USE_IRQ;
	expect_ioctl_error(device->fd, XNPU_IOC_RUN, &run, ENODATA,
			   "stale_input_after_model_load");
	printf("XNPU_STAGE5_BOUNDARY_PASS stale_input=cleared "
	       "stale_result=cleared\n");
}

static void load_model(struct xnpu_device *device,
		       const struct xnpu_package *package)
{
	int result = xnpu_device_load_model(device, package);

	if (result)
		fail("load_model", result);
	verify_model_boundary(device);
}

static int run_fixture(struct xnpu_device *device,
		       const struct xnpu_package *package,
		       const struct fixture *fixture)
{
	struct xnpu_result_v2 inference;
	uint8_t *input;
	uint8_t *output;
	size_t input_size;
	size_t name_length;
	const char *model_name;
	uint32_t top1 = 0;
	size_t index;
	int result;

	result = xnpu_read_file(fixture->input_path, &input, &input_size);
	if (result)
		fail("fixture_read", result);
	output = malloc(package->info.output.bytes);
	if (!output)
		fail("fixture_output_alloc", -ENOMEM);
	result = xnpu_device_infer(device, package, input, input_size, 30000, 1,
				   output, package->info.output.bytes,
				   &inference);
	if (result)
		fail("fixture_infer", result);
	if (package->info.task == XNPU_TASK_CLASSIFICATION)
		top1 = xnpu_top1_u8(output, package->info.output.bytes);
	model_name = xnpu_package_name(package, &name_length);
	printf("XNPU_STAGE5_RESULT model=%.*s fixture=%s checksum=0x%08x "
	       "bytes=",
	       (int)name_length, model_name, fixture->name,
	       inference.result_checksum);
	for (index = 0; index < package->info.output.bytes; ++index)
		printf("%s%u", index ? "," : "", output[index]);
	printf("\n");
	if (inference.result_checksum != fixture->checksum ||
	    fixture->expected_size > package->info.output.bytes ||
	    memcmp(output, fixture->expected, fixture->expected_size) ||
	    (package->info.task == XNPU_TASK_CLASSIFICATION &&
	     top1 != fixture->top1)) {
		++golden_failures;
		printf("XNPU_STAGE5_ITEM_FAIL model=%.*s fixture=%s "
		       "expected_checksum=0x%08x expected_top1=%u\n",
		       (int)name_length, model_name, fixture->name,
		       fixture->checksum, fixture->top1);
		free(output);
		free(input);
		return -EBADMSG;
	}
	++completed_items;
	printf("XNPU_STAGE5_ITEM_PASS index=%u model=%.*s fixture=%s "
	       "checksum=0x%08x",
	       completed_items, (int)name_length, model_name, fixture->name,
	       inference.result_checksum);
	if (package->info.task == XNPU_TASK_BBOX)
		printf(" bbox=%u,%u,%u,%u,%u", output[0], output[1],
		       output[2], output[3], output[4]);
	else
		printf(" top1=%u", top1);
	printf(" perf_cycle=%u\n", inference.perf_cycles);
	free(output);
	free(input);
	return 0;
}

static void run_model(struct xnpu_device *device, const char *package_path,
		      const struct fixture *fixture)
{
	struct xnpu_package package;
	int result;

	result = xnpu_package_open(&package, package_path);
	if (result)
		fail("package_open", result);
	load_model(device, &package);
	(void)run_fixture(device, &package, fixture);
	xnpu_package_close(&package);
}

static void invalid_model_tests(struct xnpu_device *device,
				const struct xnpu_package *package)
{
	const struct xnpu_section *descriptors =
		xnpu_package_section(package, XNPU_SECTION_DESCRIPTORS);
	struct xnpu_model model;
	uint32_t *bad_descriptors;

	bad_descriptors = malloc(descriptors->size);
	if (!bad_descriptors)
		fail("bad_descriptor_alloc", -ENOMEM);
	memcpy(bad_descriptors, descriptors->data, descriptors->size);
	bad_descriptors[5] = package->info.parameter_bytes / sizeof(uint32_t);
	fill_model_request(package, &model, bad_descriptors);
	expect_ioctl_error(device->fd, XNPU_IOC_LOAD_MODEL, &model, EINVAL,
			   "bad_descriptor_not_rejected");
	printf("XNPU_STAGE5_ERROR_PASS kind=bad_descriptor error=%d\n",
	       EINVAL);
	free(bad_descriptors);

	fill_model_request(package, &model, descriptors->data);
	model.scratch_bytes = device->caps.max_scratch_bytes + 16U;
	expect_ioctl_error(device->fd, XNPU_IOC_LOAD_MODEL, &model, EINVAL,
			   "oversize_model_not_rejected");
	printf("XNPU_STAGE5_ERROR_PASS kind=oversize_model error=%d\n",
	       EINVAL);

	/* Both validation failures occur before reset and must preserve FaceNet. */
	if (run_fixture(device, package, &facenet_seed42))
		fail("preserved_model_golden", -EBADMSG);
	printf("XNPU_STAGE5_PRESERVE_PASS model=facenet_bbox\n");
}

static void timeout_reset_recovery(struct xnpu_device *device,
				   const struct xnpu_package *package)
{
	struct xnpu_result_v2 result;
	struct xnpu_input input_request;
	struct xnpu_run run;
	uint8_t *input;
	size_t input_size;
	int ioctl_result;
	int status;

	status = xnpu_read_file(facenet_seed42.input_path, &input, &input_size);
	if (status)
		fail("timeout_fixture_read", status);
	memset(&input_request, 0, sizeof(input_request));
	input_request.mode = package->info.input_mode;
	input_request.bytes = package->info.input.bytes;
	input_request.data = (uint64_t)(uintptr_t)input;
	if (ioctl(device->fd, XNPU_IOC_LOAD_INPUT, &input_request) < 0)
		fail("timeout_load_input", -errno);
	memset(&run, 0, sizeof(run));
	/*
	 * Exercise the polling path here: it uses a high-resolution deadline,
	 * so a 1 ms timeout is deterministic even when the kernel tick is
	 * coarser than one millisecond.
	 */
	run.flags = 0;
	if (ioctl(device->fd, XNPU_IOC_RUN, &run) < 0)
		fail("timeout_run", -errno);
	memset(&result, 0, sizeof(result));
	result.timeout_ms = 1;
	errno = 0;
	ioctl_result = ioctl(device->fd, XNPU_IOC_WAIT_V2, &result);
	if (ioctl_result != -1 || errno != ETIMEDOUT)
		fail("timeout_not_observed",
		     ioctl_result == -1 ? -errno : -EIO);
	printf("XNPU_STAGE5_ERROR_PASS kind=timeout error=%d\n", ETIMEDOUT);
	if (ioctl(device->fd, XNPU_IOC_RESET) < 0)
		fail("timeout_reset", -errno);
	expect_ioctl_error(device->fd, XNPU_IOC_LOAD_INPUT,
			   &input_request, ENODATA,
			   "reset_did_not_drop_model");
	free(input);

	load_model(device, package);
	if (run_fixture(device, package, &facenet_seed42))
		fail("recovery_golden", -EBADMSG);
	printf("XNPU_STAGE5_RECOVERY_PASS reset_reload=ok\n");
}

int main(void)
{
	struct xnpu_package facenet;
	struct xnpu_device device;
	int result;

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("XNPU Stage-5 Linux regression start\n");
	if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 &&
	    errno != EBUSY)
		fail("mount_devtmpfs", -errno);

	package_error_tests();
	result = xnpu_device_open(&device, "/dev/xnpu");
	if (result)
		fail("device_open", result);
	printf("driver_abi=%u hardware_abi=%u caps=0x%08x "
	       "max_layers=%u max_parameter=%u max_scratch=%u\n",
	       device.info.abi_version, device.caps.hardware_abi,
	       device.caps.capabilities, device.caps.max_layers,
	       device.caps.max_parameter_bytes, device.caps.max_scratch_bytes);

	result = xnpu_package_open(&facenet,
				   "/models/facenet_lbp_v1.xnpu");
	if (result)
		fail("facenet_package_open", result);
	load_model(&device, &facenet);
	(void)run_fixture(&device, &facenet, &facenet_seed42);
	(void)run_fixture(&device, &facenet, &facenet_seed7);
	xnpu_package_close(&facenet);

	run_model(&device, "/models/mnist_lenet_v1.xnpu",
		  &mnist_lenet_7);
	run_model(&device, "/models/npu_vgg_s1_v1.xnpu",
		  &npu_vgg_s1_demo);
	run_model(&device, "/models/npu_vgg_s2b_v1.xnpu",
		  &npu_vgg_s2b_demo);

	result = xnpu_package_open(&facenet,
				   "/models/facenet_lbp_v1.xnpu");
	if (result)
		fail("facenet_loop_package_open", result);
	load_model(&device, &facenet);
	(void)run_fixture(&device, &facenet, &facenet_seed42);
	printf("XNPU_STAGE5_SWITCH_PASS sequence="
	       "FaceNet,LeNet,VGG-S1,VGG-S2b,FaceNet\n");

	invalid_model_tests(&device, &facenet);
	timeout_reset_recovery(&device, &facenet);

	if (golden_failures)
		fail("golden_mismatches", -EBADMSG);
	printf("XNPU_STAGE5_PASS items=%u package_errors=4 "
	       "driver_errors=3 recovery=1\n", completed_items);
	xnpu_package_close(&facenet);
	xnpu_device_close(&device);
	finish_forever();
	return 0;
}
