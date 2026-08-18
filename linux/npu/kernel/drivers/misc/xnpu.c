// SPDX-License-Identifier: GPL-2.0
/*
 * XNPU neural-network accelerator driver
 *
 * ABI v1 keeps the ROM/MMIO bring-up path.  ABI v2 adds one active
 * descriptor/parameter model and kernel-owned coherent DMA buffers.
 */

#include <linux/atomic.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include <linux/xnpu.h>

#define XNPU_REG_CTRL			0x0000
#define XNPU_REG_STATUS			0x0004
#define XNPU_REG_FRAME_COUNT		0x000c
#define XNPU_REG_BBOX0			0x0010
#define XNPU_REG_BBOX1			0x0014
#define XNPU_REG_IRQ_STATUS			0x0018
#define XNPU_REG_IRQ_CLEAR			0x001c
#define XNPU_REG_PERF_CYCLES		0x0028
#define XNPU_REG_SCRATCH_BASE		0x002c
#define XNPU_REG_PARAMETER_BASE		0x0030
#define XNPU_REG_LAYER_COUNT		0x0034
#define XNPU_REG_DESC_CTRL			0x0038
#define XNPU_REG_DESC_STATUS		0x003c

#define XNPU_REG_RESULT_CTRL		0x0120
#define XNPU_REG_RESULT_STATUS		0x0124
#define XNPU_REG_RESULT_BASE		0x0128
#define XNPU_REG_RESULT_BYTES		0x012c
#define XNPU_REG_RESULT_WRITE_BYTES		0x0130
#define XNPU_REG_RESULT_CHECKSUM		0x0134
#define XNPU_REG_RESULT_SHAPE0		0x013c
#define XNPU_REG_RESULT_SHAPE1		0x0140
#define XNPU_REG_INPUT_PRELOAD_CTRL		0x0144
#define XNPU_REG_INPUT_PRELOAD_STATUS	0x0148
#define XNPU_REG_INPUT_PRELOAD_BYTES	0x014c
#define XNPU_REG_INPUT_PRELOAD_COUNT	0x0150
#define XNPU_REG_INPUT_PRELOAD_DATA		0x0154
#define XNPU_REG_HW_CAPS			0x0158
#define XNPU_REG_HW_ABI			0x015c

#define XNPU_FRAME_MEM_BASE			0x1000
#define XNPU_DESC_RAM_BASE			0x6000

#define XNPU_CTRL_START			BIT(0)
#define XNPU_CTRL_SOFT_RESET		BIT(1)
#define XNPU_CTRL_IRQ_ENABLE		BIT(2)
#define XNPU_CTRL_CLEAR_FRAME		BIT(3)
#define XNPU_CTRL_CLEAR_STATUS		BIT(4)

#define XNPU_STATUS_BUSY			BIT(0)
#define XNPU_STATUS_DONE			BIT(1)
#define XNPU_STATUS_ERROR			BIT(2)
#define XNPU_STATUS_FRAME_FULL		BIT(3)

#define XNPU_DESC_ENABLE			BIT(0)
#define XNPU_DESC_READY			BIT(0)
#define XNPU_DESC_ERROR			BIT(1)

#define XNPU_RESULT_ENABLE			BIT(0)
#define XNPU_RESULT_CLEAR_STATUS		BIT(1)
#define XNPU_RESULT_BUSY			BIT(0)
#define XNPU_RESULT_DONE			BIT(1)
#define XNPU_RESULT_ERROR			BIT(2)

#define XNPU_PRELOAD_ENABLE			BIT(0)
#define XNPU_PRELOAD_CLEAR_COUNT		BIT(2)
#define XNPU_PRELOAD_PACKED			BIT(3)
#define XNPU_PRELOAD_SKIP_LBP		BIT(4)
#define XNPU_PRELOAD_DONE			BIT(1)
#define XNPU_PRELOAD_ERROR			BIT(2)
#define XNPU_PRELOAD_TARGET_UNSUPPORTED	BIT(3)
#define XNPU_PRELOAD_OVERFLOW		BIT(4)
#define XNPU_PRELOAD_ERROR_MASK \
	(XNPU_PRELOAD_ERROR | XNPU_PRELOAD_TARGET_UNSUPPORTED | \
	 XNPU_PRELOAD_OVERFLOW)

#define XNPU_HW_CAP_AXI_DMA			BIT(0)
#define XNPU_HW_CAP_PACKED_PRELOAD		BIT(1)
#define XNPU_HW_CAP_RESULT_WRITEBACK	BIT(2)
#define XNPU_HW_CAP_DESCRIPTOR_RAM		BIT(3)

#define XNPU_BBOX_VALID			BIT(8)
#define XNPU_MIN_SCRATCH_BYTES		(19200U * 16U)

struct xnpu_dma_buffer {
	void *cpu_addr;
	dma_addr_t dma_addr;
	size_t bytes;
	enum dma_data_direction direction;
	bool noncoherent;
};

struct xnpu {
	void __iomem *base;
	struct device *dev;
	struct miscdevice miscdev;
	struct completion completion;
	struct mutex lock;
	atomic_t opened;
	int irq;

	u32 hardware_abi;
	u32 capabilities;
	bool run_uses_irq;
	bool run_active;
	bool legacy_descriptors_loaded;
	bool model_loaded;
	bool input_loaded;
	bool result_ready;
	u32 result_actual_bytes;

	struct xnpu_model model;
	struct xnpu_dma_buffer parameter;
	struct xnpu_dma_buffer scratch;
	struct xnpu_dma_buffer result;
};

static inline u32 xnpu_read(struct xnpu *npu, u32 offset)
{
	return readl(npu->base + offset);
}

static inline void xnpu_write(struct xnpu *npu, u32 offset, u32 value)
{
	writel(value, npu->base + offset);
}

static bool xnpu_u32_array_is_zero(const u32 *values, size_t count)
{
	size_t index;

	for (index = 0; index < count; ++index) {
		if (values[index])
			return false;
	}
	return true;
}

static void xnpu_free_dma_buffer(struct xnpu *npu,
				     struct xnpu_dma_buffer *buffer)
{
	if (buffer->cpu_addr) {
		if (buffer->noncoherent)
			dma_free_noncoherent(npu->dev, buffer->bytes,
					     buffer->cpu_addr, buffer->dma_addr,
					     buffer->direction);
		else
			dma_free_coherent(npu->dev, buffer->bytes,
					  buffer->cpu_addr, buffer->dma_addr);
	}
	memset(buffer, 0, sizeof(*buffer));
}

static int xnpu_check_dma_buffer(struct xnpu *npu,
				     struct xnpu_dma_buffer *buffer,
				     size_t bytes)
{
	buffer->bytes = bytes;
	if (upper_32_bits(buffer->dma_addr) ||
	    bytes - 1 > U32_MAX - lower_32_bits(buffer->dma_addr)) {
		xnpu_free_dma_buffer(npu, buffer);
		return -ERANGE;
	}
	return 0;
}

static int xnpu_alloc_dma_buffer(struct xnpu *npu,
				     struct xnpu_dma_buffer *buffer,
				     size_t bytes)
{
	buffer->cpu_addr = dma_alloc_coherent(npu->dev, bytes,
					      &buffer->dma_addr, GFP_KERNEL);
	if (!buffer->cpu_addr)
		return -ENOMEM;
	buffer->bytes = bytes;

	memset(buffer->cpu_addr, 0, bytes);
	return xnpu_check_dma_buffer(npu, buffer, bytes);
}

static int xnpu_alloc_noncoherent_dma_buffer(
	struct xnpu *npu, struct xnpu_dma_buffer *buffer,
	size_t bytes, enum dma_data_direction direction)
{
	buffer->cpu_addr = dma_alloc_noncoherent(npu->dev, bytes,
						 &buffer->dma_addr, direction,
						 GFP_KERNEL);
	if (!buffer->cpu_addr)
		return -ENOMEM;
	buffer->bytes = bytes;
	buffer->direction = direction;
	buffer->noncoherent = true;
	memset(buffer->cpu_addr, 0, bytes);
	return xnpu_check_dma_buffer(npu, buffer, bytes);
}

static void xnpu_drop_model(struct xnpu *npu)
{
	xnpu_free_dma_buffer(npu, &npu->parameter);
	xnpu_free_dma_buffer(npu, &npu->scratch);
	xnpu_free_dma_buffer(npu, &npu->result);
	memset(&npu->model, 0, sizeof(npu->model));
	npu->model_loaded = false;
	npu->input_loaded = false;
	npu->result_ready = false;
	npu->result_actual_bytes = 0;
}

static void xnpu_reset_hardware(struct xnpu *npu)
{
	reinit_completion(&npu->completion);
	npu->run_uses_irq = false;
	npu->run_active = false;
	npu->legacy_descriptors_loaded = false;
	npu->model_loaded = false;
	npu->input_loaded = false;
	npu->result_ready = false;
	npu->result_actual_bytes = 0;
	xnpu_write(npu, XNPU_REG_CTRL, XNPU_CTRL_SOFT_RESET);
	udelay(1);
	xnpu_write(npu, XNPU_REG_IRQ_CLEAR, BIT(0));
}

static void xnpu_reset_device(struct xnpu *npu)
{
	xnpu_reset_hardware(npu);
	xnpu_drop_model(npu);
}

static irqreturn_t xnpu_irq(int irq, void *data)
{
	struct xnpu *npu = data;

	if (!(xnpu_read(npu, XNPU_REG_IRQ_STATUS) & BIT(0)))
		return IRQ_NONE;

	xnpu_write(npu, XNPU_REG_IRQ_CLEAR, BIT(0));
	complete(&npu->completion);
	return IRQ_HANDLED;
}

static int xnpu_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct xnpu *npu = container_of(misc, struct xnpu, miscdev);

	if (atomic_cmpxchg(&npu->opened, 0, 1))
		return -EBUSY;

	file->private_data = npu;
	return nonseekable_open(inode, file);
}

static int xnpu_release(struct inode *inode, struct file *file)
{
	struct xnpu *npu = file->private_data;

	mutex_lock(&npu->lock);
	xnpu_reset_device(npu);
	mutex_unlock(&npu->lock);
	atomic_set(&npu->opened, 0);
	return 0;
}

static int xnpu_validate_descriptors(const u32 *descriptors, u32 count,
					 u32 parameter_bytes)
{
	u32 layer;

	for (layer = 0; layer < count; ++layer) {
		const u32 *desc = descriptors + layer * XNPU_DESC_WORDS;
		u32 cin = desc[2] & 0xffff;
		u32 cout = desc[2] >> 16;
		u32 input_width = desc[3] & 0xffff;
		u32 input_height = desc[3] >> 16;
		u32 output_width = desc[4] & 0xffff;
		u32 output_height = desc[4] >> 16;
		u32 weight_offset = (desc[5] & 0xffff) * sizeof(u32);
		u32 bias_offset = (desc[6] & 0xffff) * sizeof(u32);

		if (!cin || !cout || !input_width || !input_height ||
		    !output_width || !output_height)
			return -EINVAL;
		if ((desc[5] >> 16) || (desc[6] >> 16))
			return -EINVAL;
		if (weight_offset >= parameter_bytes ||
		    bias_offset >= parameter_bytes)
			return -EINVAL;
	}
	return 0;
}

static int xnpu_program_descriptors(struct xnpu *npu,
					 const u32 *descriptors, u32 count)
{
	u32 status;
	u32 layer;
	u32 word;
	int ret;

	xnpu_write(npu, XNPU_REG_DESC_CTRL, XNPU_DESC_ENABLE);
	for (layer = 0; layer < count; ++layer) {
		for (word = 0; word < XNPU_DESC_WORDS; ++word) {
			u32 offset = XNPU_DESC_RAM_BASE +
				(layer * XNPU_DESC_WORDS + word) *
				sizeof(u32);

			xnpu_write(npu, offset,
				       descriptors[layer * XNPU_DESC_WORDS +
						   word]);
		}
	}
	xnpu_write(npu, XNPU_REG_LAYER_COUNT, count);

	ret = readl_poll_timeout(npu->base + XNPU_REG_DESC_STATUS,
				 status,
				 status & (XNPU_DESC_READY |
					   XNPU_DESC_ERROR),
				 1, 10000);
	if (ret)
		return ret;
	if (status & XNPU_DESC_ERROR)
		return -EIO;
	return 0;
}

static int xnpu_load_legacy_descriptors(
	struct xnpu *npu, const struct xnpu_descriptors *request)
{
	size_t bytes;
	u32 *descriptors;
	int ret;

	if (!request->count || request->count > XNPU_MAX_LAYERS ||
	    request->reserved || !request->data)
		return -EINVAL;
	if (xnpu_read(npu, XNPU_REG_STATUS) & XNPU_STATUS_BUSY)
		return -EBUSY;

	bytes = request->count * XNPU_DESC_WORDS * sizeof(u32);
	descriptors = memdup_user(u64_to_user_ptr(request->data), bytes);
	if (IS_ERR(descriptors))
		return PTR_ERR(descriptors);

	ret = xnpu_program_descriptors(npu, descriptors, request->count);
	kfree(descriptors);
	if (!ret)
		npu->legacy_descriptors_loaded = true;
	return ret;
}

static unsigned int xnpu_dtype_bytes(u32 dtype)
{
	switch (dtype) {
	case XNPU_DTYPE_U8:
	case XNPU_DTYPE_S8:
		return 1;
	case XNPU_DTYPE_U16:
	case XNPU_DTYPE_S16:
		return 2;
	case XNPU_DTYPE_U32:
	case XNPU_DTYPE_S32:
		return 4;
	default:
		return 0;
	}
}

static int xnpu_validate_model(const struct xnpu_model *model)
{
	u64 tensor_bytes;
	unsigned int dtype_bytes;

	if (model->flags || !model->descriptors || !model->parameters ||
	    !xnpu_u32_array_is_zero(model->reserved,
					 ARRAY_SIZE(model->reserved)))
		return -EINVAL;
	if (!model->layer_count || model->layer_count > XNPU_MAX_LAYERS)
		return -EINVAL;
	if (!model->parameter_bytes ||
	    model->parameter_bytes > XNPU_MAX_PARAMETER_BYTES ||
	    model->parameter_bytes % sizeof(u32))
		return -EINVAL;
	if (model->scratch_bytes < XNPU_MIN_SCRATCH_BYTES ||
	    model->scratch_bytes > XNPU_MAX_SCRATCH_BYTES ||
	    model->scratch_bytes % 16)
		return -EINVAL;
	if (!model->result_bytes ||
	    model->result_bytes > XNPU_MAX_RESULT_BYTES)
		return -EINVAL;

	if (model->input_mode == XNPU_INPUT_FRAME) {
		if (model->input_bytes != XNPU_FRAME_BYTES)
			return -EINVAL;
	} else if (model->input_mode == XNPU_INPUT_PACKED_PRELOAD) {
		if (!model->input_bytes ||
		    model->input_bytes > XNPU_MAX_INPUT_BYTES)
			return -EINVAL;
	} else {
		return -EINVAL;
	}

	if (!model->result_width || !model->result_height ||
	    !model->result_channels ||
	    model->result_width > 0xffff ||
	    model->result_height > 0xffff ||
	    model->result_channels > 0xffff ||
	    model->result_layout > XNPU_LAYOUT_NCHW)
		return -EINVAL;

	dtype_bytes = xnpu_dtype_bytes(model->result_dtype);
	if (!dtype_bytes)
		return -EINVAL;
	tensor_bytes = (u64)model->result_width * model->result_height;
	tensor_bytes *= model->result_channels;
	tensor_bytes *= dtype_bytes;
	if (tensor_bytes > model->result_bytes)
		return -EINVAL;
	return 0;
}

static int xnpu_program_model(struct xnpu *npu,
				   const struct xnpu_model *model,
				   const u32 *descriptors,
				   const struct xnpu_dma_buffer *parameter,
				   const struct xnpu_dma_buffer *scratch,
				   const struct xnpu_dma_buffer *result)
{
	u32 shape0 = model->result_width | (model->result_height << 16);
	u32 shape1 = model->result_channels |
		     (model->result_layout << 16) |
		     (model->result_dtype << 24);
	int ret;

	xnpu_write(npu, XNPU_REG_PARAMETER_BASE,
		       lower_32_bits(parameter->dma_addr));
	xnpu_write(npu, XNPU_REG_SCRATCH_BASE,
		       lower_32_bits(scratch->dma_addr));
	xnpu_write(npu, XNPU_REG_RESULT_BASE,
		       lower_32_bits(result->dma_addr));
	xnpu_write(npu, XNPU_REG_RESULT_BYTES, model->result_bytes);
	xnpu_write(npu, XNPU_REG_RESULT_SHAPE0, shape0);
	xnpu_write(npu, XNPU_REG_RESULT_SHAPE1, shape1);
	xnpu_write(npu, XNPU_REG_RESULT_CTRL,
		       XNPU_RESULT_CLEAR_STATUS);
	xnpu_write(npu, XNPU_REG_RESULT_CTRL,
		       XNPU_RESULT_ENABLE);

	ret = xnpu_program_descriptors(npu, descriptors,
					   model->layer_count);
	return ret;
}

static int xnpu_load_model(struct xnpu *npu,
				const struct xnpu_model *request)
{
	struct xnpu_dma_buffer parameter = {};
	struct xnpu_dma_buffer scratch = {};
	struct xnpu_dma_buffer result = {};
	size_t descriptor_bytes;
	u32 *descriptors;
	int ret;

	if (!(npu->capabilities & XNPU_CAP_AXI_DMA))
		return -EOPNOTSUPP;
	if (xnpu_read(npu, XNPU_REG_STATUS) & XNPU_STATUS_BUSY)
		return -EBUSY;

	ret = xnpu_validate_model(request);
	if (ret)
		return ret;

	descriptor_bytes = request->layer_count * XNPU_DESC_WORDS *
			   sizeof(u32);
	descriptors = memdup_user(u64_to_user_ptr(request->descriptors),
				  descriptor_bytes);
	if (IS_ERR(descriptors))
		return PTR_ERR(descriptors);

	ret = xnpu_validate_descriptors(descriptors, request->layer_count,
					    request->parameter_bytes);
	if (ret)
		goto out_descriptors;

	/*
	 * Keep the CPU mapping cacheable while loading the immutable parameter
	 * image, then hand it to the accelerator through the streaming DMA API.
	 * OpenLA500 loses some bulk CPU stores to dma_alloc_coherent()'s
	 * uncached alias.
	 */
	ret = xnpu_alloc_noncoherent_dma_buffer(
		npu, &parameter, request->parameter_bytes, DMA_TO_DEVICE);
	if (ret)
		goto out_descriptors;
	if (copy_from_user(parameter.cpu_addr,
			   u64_to_user_ptr(request->parameters),
			   request->parameter_bytes)) {
		ret = -EFAULT;
		goto out_buffers;
	}
	dma_sync_single_for_device(npu->dev, parameter.dma_addr,
				   parameter.bytes, DMA_TO_DEVICE);

	ret = xnpu_alloc_dma_buffer(npu, &scratch, request->scratch_bytes);
	if (ret)
		goto out_buffers;
	ret = xnpu_alloc_dma_buffer(npu, &result, request->result_bytes);
	if (ret)
		goto out_buffers;

	/*
	 * Keep the previous buffers until all new userspace data and allocations
	 * are valid.  The hardware is reset before the old buffers are freed.
	 */
	xnpu_reset_hardware(npu);
	xnpu_drop_model(npu);
	ret = xnpu_program_model(npu, request, descriptors, &parameter,
				      &scratch, &result);
	if (ret) {
		xnpu_reset_hardware(npu);
		goto out_buffers;
	}

	npu->parameter = parameter;
	npu->scratch = scratch;
	npu->result = result;
	memset(&parameter, 0, sizeof(parameter));
	memset(&scratch, 0, sizeof(scratch));
	memset(&result, 0, sizeof(result));
	npu->model = *request;
	npu->model.descriptors = 0;
	npu->model.parameters = 0;
	npu->model_loaded = true;
	npu->input_loaded = false;
	npu->result_ready = false;
	ret = 0;

out_buffers:
	xnpu_free_dma_buffer(npu, &result);
	xnpu_free_dma_buffer(npu, &scratch);
	xnpu_free_dma_buffer(npu, &parameter);
out_descriptors:
	kfree(descriptors);
	return ret;
}

static int xnpu_load_frame(struct xnpu *npu, const u8 *frame,
				size_t bytes)
{
	u32 status;
	unsigned int offset;

	if (bytes != XNPU_FRAME_BYTES)
		return -EINVAL;

	xnpu_write(npu, XNPU_REG_CTRL,
		       XNPU_CTRL_CLEAR_FRAME |
		       XNPU_CTRL_CLEAR_STATUS);
	for (offset = 0; offset < bytes; offset += sizeof(u32)) {
		u32 value = (u32)frame[offset] |
			((u32)frame[offset + 1] << 8) |
			((u32)frame[offset + 2] << 16) |
			((u32)frame[offset + 3] << 24);

		xnpu_write(npu, XNPU_FRAME_MEM_BASE + offset, value);
	}

	status = xnpu_read(npu, XNPU_REG_STATUS);
	if (xnpu_read(npu, XNPU_REG_FRAME_COUNT) != bytes ||
	    !(status & XNPU_STATUS_FRAME_FULL))
		return -EIO;
	return 0;
}

static int xnpu_load_packed_input(struct xnpu *npu,
				      const u8 *input, size_t bytes)
{
	u32 status;
	unsigned int offset;
	int ret;

	xnpu_write(npu, XNPU_REG_CTRL,
		       XNPU_CTRL_CLEAR_STATUS);
	xnpu_write(npu, XNPU_REG_INPUT_PRELOAD_CTRL,
		       XNPU_PRELOAD_CLEAR_COUNT);
	xnpu_write(npu, XNPU_REG_INPUT_PRELOAD_BYTES, bytes);
	xnpu_write(npu, XNPU_REG_INPUT_PRELOAD_CTRL,
		       XNPU_PRELOAD_ENABLE |
		       XNPU_PRELOAD_PACKED |
		       XNPU_PRELOAD_SKIP_LBP);

	for (offset = 0; offset < bytes; offset += sizeof(u32)) {
		size_t remain = bytes - offset;
		u32 value = input[offset];

		if (remain > 1)
			value |= (u32)input[offset + 1] << 8;
		if (remain > 2)
			value |= (u32)input[offset + 2] << 16;
		if (remain > 3)
			value |= (u32)input[offset + 3] << 24;
		xnpu_write(npu, XNPU_REG_INPUT_PRELOAD_DATA, value);
	}

	ret = readl_poll_timeout(npu->base +
				 XNPU_REG_INPUT_PRELOAD_STATUS,
				 status,
				 status & (XNPU_PRELOAD_DONE |
					   XNPU_PRELOAD_ERROR_MASK),
				 1, 10000);
	if (ret)
		return ret;
	if (status & XNPU_PRELOAD_ERROR_MASK)
		return -EIO;
	if (xnpu_read(npu, XNPU_REG_INPUT_PRELOAD_COUNT) != bytes)
		return -EIO;
	return 0;
}

static int xnpu_load_input(struct xnpu *npu,
				const struct xnpu_input *request)
{
	u8 *input;
	u32 status;
	int ret;

	if (request->flags || request->reserved || !request->data)
		return -EINVAL;
	if (!npu->model_loaded)
		return -ENODATA;
	if (request->mode != npu->model.input_mode ||
	    request->bytes != npu->model.input_bytes)
		return -EINVAL;

	status = xnpu_read(npu, XNPU_REG_STATUS);
	if ((status & XNPU_STATUS_BUSY) || npu->run_active)
		return -EBUSY;

	input = memdup_user(u64_to_user_ptr(request->data), request->bytes);
	if (IS_ERR(input))
		return PTR_ERR(input);

	if (request->mode == XNPU_INPUT_FRAME)
		ret = xnpu_load_frame(npu, input, request->bytes);
	else
		ret = xnpu_load_packed_input(npu, input, request->bytes);
	kfree(input);

	if (!ret) {
		npu->input_loaded = true;
		npu->result_ready = false;
		npu->result_actual_bytes = 0;
	}
	return ret;
}

static ssize_t xnpu_file_write(struct file *file,
				   const char __user *buffer,
				   size_t count, loff_t *position)
{
	struct xnpu *npu = file->private_data;
	u8 *frame;
	u32 status;
	int ret;

	if (count != XNPU_FRAME_BYTES)
		return -EINVAL;

	frame = memdup_user(buffer, count);
	if (IS_ERR(frame))
		return PTR_ERR(frame);

	mutex_lock(&npu->lock);
	status = xnpu_read(npu, XNPU_REG_STATUS);
	if ((status & XNPU_STATUS_BUSY) || npu->run_active) {
		ret = -EBUSY;
		goto out;
	}
	if ((npu->capabilities & XNPU_CAP_AXI_DMA) &&
	    (!npu->model_loaded ||
	     npu->model.input_mode != XNPU_INPUT_FRAME)) {
		ret = -ENODATA;
		goto out;
	}

	ret = xnpu_load_frame(npu, frame, count);
	if (!ret) {
		npu->input_loaded = true;
		npu->result_ready = false;
		npu->result_actual_bytes = 0;
	}
out:
	mutex_unlock(&npu->lock);
	kfree(frame);
	return ret ? ret : count;
}

static ssize_t xnpu_file_read(struct file *file, char __user *buffer,
				  size_t count, loff_t *position)
{
	struct xnpu *npu = file->private_data;
	size_t available;
	size_t bytes;
	ssize_t ret;

	mutex_lock(&npu->lock);
	if (!npu->model_loaded || !npu->result_ready ||
	    !npu->result.cpu_addr) {
		ret = -ENODATA;
		goto out;
	}
	if (*position < 0) {
		ret = -EINVAL;
		goto out;
	}
	if (*position >= npu->result_actual_bytes) {
		ret = 0;
		goto out;
	}

	available = npu->result_actual_bytes - *position;
	bytes = min(count, available);
	dma_rmb();
	if (copy_to_user(buffer, npu->result.cpu_addr + *position, bytes)) {
		ret = -EFAULT;
		goto out;
	}
	*position += bytes;
	ret = bytes;
out:
	mutex_unlock(&npu->lock);
	return ret;
}

static int xnpu_start(struct xnpu *npu,
			  const struct xnpu_run *run)
{
	u32 control = XNPU_CTRL_START;
	u32 status;

	if (run->reserved || run->flags & ~XNPU_RUN_USE_IRQ)
		return -EINVAL;
	if ((run->flags & XNPU_RUN_USE_IRQ) && npu->irq < 0)
		return -ENXIO;

	status = xnpu_read(npu, XNPU_REG_STATUS);
	if ((status & XNPU_STATUS_BUSY) || npu->run_active)
		return -EBUSY;

	if (npu->capabilities & XNPU_CAP_AXI_DMA) {
		if (!npu->model_loaded || !npu->input_loaded)
			return -ENODATA;
		memset(npu->result.cpu_addr, 0, npu->result.bytes);
		xnpu_write(npu, XNPU_REG_RESULT_CTRL,
			       XNPU_RESULT_ENABLE |
			       XNPU_RESULT_CLEAR_STATUS);
		xnpu_write(npu, XNPU_REG_RESULT_CTRL,
			       XNPU_RESULT_ENABLE);
		dma_wmb();
	} else if (!(status & XNPU_STATUS_FRAME_FULL)) {
		return -ENODATA;
	}

	reinit_completion(&npu->completion);
	xnpu_write(npu, XNPU_REG_IRQ_CLEAR, BIT(0));
	xnpu_write(npu, XNPU_REG_CTRL,
		       XNPU_CTRL_CLEAR_STATUS);

	npu->run_uses_irq = run->flags & XNPU_RUN_USE_IRQ;
	npu->run_active = true;
	npu->result_ready = false;
	npu->result_actual_bytes = 0;
	if (npu->run_uses_irq)
		control |= XNPU_CTRL_IRQ_ENABLE;
	xnpu_write(npu, XNPU_REG_CTRL, control);

	status = xnpu_read(npu, XNPU_REG_STATUS);
	if (!(status & (XNPU_STATUS_BUSY | XNPU_STATUS_DONE))) {
		npu->run_active = false;
		return -EIO;
	}
	return 0;
}

static int xnpu_wait_terminal(struct xnpu *npu, u32 timeout_ms,
				   u32 *status_out)
{
	unsigned long timeout;
	ktime_t deadline;
	u32 result_status;
	u32 status;
	long wait_ret;

	if (!timeout_ms)
		return -EINVAL;
	if (!npu->run_active)
		return -ENODATA;

	timeout = msecs_to_jiffies(timeout_ms);
	if (npu->run_uses_irq) {
		wait_ret = wait_for_completion_interruptible_timeout(
			&npu->completion, timeout);
		if (wait_ret < 0)
			return wait_ret;
		if (!wait_ret)
			return -ETIMEDOUT;
	} else {
		deadline = ktime_add_ms(ktime_get(), timeout_ms);
		do {
			status = xnpu_read(npu, XNPU_REG_STATUS);
			if (status & (XNPU_STATUS_DONE |
				      XNPU_STATUS_ERROR))
				break;
			usleep_range(100, 200);
		} while (ktime_before(ktime_get(), deadline));
	}

	status = xnpu_read(npu, XNPU_REG_STATUS);
	*status_out = status;
	if (status & XNPU_STATUS_ERROR) {
		npu->run_active = false;
		return -EIO;
	}
	if (!(status & XNPU_STATUS_DONE))
		return -ETIMEDOUT;

	npu->run_active = false;
	if (!(npu->capabilities & XNPU_CAP_AXI_DMA))
		return 0;

	result_status = xnpu_read(npu, XNPU_REG_RESULT_STATUS);
	if ((result_status & XNPU_RESULT_ERROR) ||
	    !(result_status & XNPU_RESULT_DONE))
		return -EIO;

	npu->result_actual_bytes =
		xnpu_read(npu, XNPU_REG_RESULT_WRITE_BYTES);
	if (!npu->result_actual_bytes ||
	    npu->result_actual_bytes > npu->model.result_bytes ||
	    npu->result_actual_bytes > npu->result.bytes) {
		npu->result_actual_bytes = 0;
		return -EIO;
	}
	dma_rmb();
	npu->result_ready = true;
	return 0;
}

static int xnpu_wait_legacy(struct xnpu *npu,
				 struct xnpu_result *result)
{
	u32 timeout_ms = result->timeout_ms;
	u32 bbox0;
	u32 bbox1;
	u32 status;
	int ret;

	memset(result, 0, sizeof(*result));
	result->timeout_ms = timeout_ms;
	ret = xnpu_wait_terminal(npu, timeout_ms, &status);
	if (ret)
		return ret;

	result->status = status;
	result->perf_cycles = xnpu_read(npu, XNPU_REG_PERF_CYCLES);
	bbox0 = xnpu_read(npu, XNPU_REG_BBOX0);
	bbox1 = xnpu_read(npu, XNPU_REG_BBOX1);
	result->bbox[0] = bbox0;
	result->bbox[1] = bbox0 >> 8;
	result->bbox[2] = bbox0 >> 16;
	result->bbox[3] = bbox0 >> 24;
	result->bbox[4] = bbox1;
	result->valid = !!(bbox1 & XNPU_BBOX_VALID);
	result->frame_id = bbox1 >> 16;
	return 0;
}

static int xnpu_wait_v2(struct xnpu *npu,
			     struct xnpu_result_v2 *result)
{
	u32 timeout_ms = result->timeout_ms;
	u32 status;
	int ret;

	memset(result, 0, sizeof(*result));
	result->timeout_ms = timeout_ms;
	if (!(npu->capabilities & XNPU_CAP_AXI_DMA))
		return -EOPNOTSUPP;
	ret = xnpu_wait_terminal(npu, timeout_ms, &status);
	if (ret)
		return ret;

	result->status = status;
	result->perf_cycles = xnpu_read(npu, XNPU_REG_PERF_CYCLES);
	result->result_status =
		xnpu_read(npu, XNPU_REG_RESULT_STATUS);
	result->result_bytes = npu->result_actual_bytes;
	result->result_checksum =
		xnpu_read(npu, XNPU_REG_RESULT_CHECKSUM);
	result->result_width = npu->model.result_width;
	result->result_height = npu->model.result_height;
	result->result_channels = npu->model.result_channels;
	result->result_layout = npu->model.result_layout;
	result->result_dtype = npu->model.result_dtype;
	return 0;
}

static void xnpu_fill_caps(struct xnpu *npu,
				struct xnpu_caps *caps)
{
	memset(caps, 0, sizeof(*caps));
	caps->abi_version = XNPU_ABI_VERSION;
	caps->hardware_abi = npu->hardware_abi;
	caps->capabilities = npu->capabilities;
	caps->max_layers = XNPU_MAX_LAYERS;
	caps->max_parameter_bytes = XNPU_MAX_PARAMETER_BYTES;
	caps->max_scratch_bytes = XNPU_MAX_SCRATCH_BYTES;
	caps->max_result_bytes = XNPU_MAX_RESULT_BYTES;
	caps->max_input_bytes = XNPU_MAX_INPUT_BYTES;
}

static long xnpu_ioctl(struct file *file, unsigned int command,
			   unsigned long argument)
{
	struct xnpu *npu = file->private_data;
	void __user *user_argument = (void __user *)argument;
	struct xnpu_descriptors descriptors;
	struct xnpu_result_v2 result_v2;
	struct xnpu_result result;
	struct xnpu_model model;
	struct xnpu_input input;
	struct xnpu_caps caps;
	struct xnpu_info info;
	struct xnpu_run run;
	int ret = 0;

	if (_IOC_TYPE(command) != XNPU_IOC_MAGIC)
		return -ENOTTY;

	mutex_lock(&npu->lock);
	switch (command) {
	case XNPU_IOC_GET_INFO:
		memset(&info, 0, sizeof(info));
		info.abi_version = XNPU_ABI_VERSION;
		info.frame_width = XNPU_FRAME_WIDTH;
		info.frame_height = XNPU_FRAME_HEIGHT;
		info.frame_bytes = XNPU_FRAME_BYTES;
		info.max_layers = XNPU_MAX_LAYERS;
		info.has_irq = npu->irq >= 0;
		if (copy_to_user(user_argument, &info, sizeof(info)))
			ret = -EFAULT;
		break;
	case XNPU_IOC_QUERY_CAPS:
		xnpu_fill_caps(npu, &caps);
		if (copy_to_user(user_argument, &caps, sizeof(caps)))
			ret = -EFAULT;
		break;
	case XNPU_IOC_RESET:
		xnpu_reset_device(npu);
		file->f_pos = 0;
		break;
	case XNPU_IOC_LOAD_DESCRIPTORS:
		if (copy_from_user(&descriptors, user_argument,
				   sizeof(descriptors))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_load_legacy_descriptors(npu, &descriptors);
		break;
	case XNPU_IOC_LOAD_MODEL:
		if (copy_from_user(&model, user_argument, sizeof(model))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_load_model(npu, &model);
		file->f_pos = 0;
		break;
	case XNPU_IOC_LOAD_INPUT:
		if (copy_from_user(&input, user_argument, sizeof(input))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_load_input(npu, &input);
		file->f_pos = 0;
		break;
	case XNPU_IOC_RUN:
		if (copy_from_user(&run, user_argument, sizeof(run))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_start(npu, &run);
		file->f_pos = 0;
		break;
	case XNPU_IOC_WAIT:
		if (copy_from_user(&result, user_argument, sizeof(result))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_wait_legacy(npu, &result);
		if (!ret && copy_to_user(user_argument, &result, sizeof(result)))
			ret = -EFAULT;
		break;
	case XNPU_IOC_WAIT_V2:
		if (copy_from_user(&result_v2, user_argument,
				   sizeof(result_v2))) {
			ret = -EFAULT;
			break;
		}
		ret = xnpu_wait_v2(npu, &result_v2);
		if (!ret &&
		    copy_to_user(user_argument, &result_v2, sizeof(result_v2)))
			ret = -EFAULT;
		break;
	default:
		ret = -ENOTTY;
		break;
	}
	mutex_unlock(&npu->lock);
	return ret;
}

static const struct file_operations xnpu_fops = {
	.owner = THIS_MODULE,
	.open = xnpu_open,
	.release = xnpu_release,
	.read = xnpu_file_read,
	.write = xnpu_file_write,
	.unlocked_ioctl = xnpu_ioctl,
	.llseek = no_llseek,
};

static int xnpu_probe(struct platform_device *pdev)
{
	struct xnpu *npu;
	u32 hardware_caps;
	int ret;

	npu = devm_kzalloc(&pdev->dev, sizeof(*npu), GFP_KERNEL);
	if (!npu)
		return -ENOMEM;

	npu->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(npu->base))
		return PTR_ERR(npu->base);

	npu->dev = &pdev->dev;
	npu->irq = platform_get_irq_optional(pdev, 0);
	if (npu->irq == -EPROBE_DEFER)
		return -EPROBE_DEFER;
	if (npu->irq < 0)
		npu->irq = -1;

	mutex_init(&npu->lock);
	init_completion(&npu->completion);
	atomic_set(&npu->opened, 0);
	xnpu_reset_hardware(npu);

	hardware_caps = xnpu_read(npu, XNPU_REG_HW_CAPS);
	npu->hardware_abi = xnpu_read(npu, XNPU_REG_HW_ABI);
	if (!npu->hardware_abi)
		npu->hardware_abi = 1;

	npu->capabilities = XNPU_CAP_LEGACY_MMIO;
	if (hardware_caps & XNPU_HW_CAP_DESCRIPTOR_RAM)
		npu->capabilities |= XNPU_CAP_DESCRIPTOR_RAM;
	if (hardware_caps & XNPU_HW_CAP_AXI_DMA)
		npu->capabilities |= XNPU_CAP_AXI_DMA;
	if (hardware_caps & XNPU_HW_CAP_PACKED_PRELOAD)
		npu->capabilities |= XNPU_CAP_PACKED_PRELOAD;
	if (hardware_caps & XNPU_HW_CAP_RESULT_WRITEBACK)
		npu->capabilities |= XNPU_CAP_RESULT_WRITEBACK;

	if (npu->capabilities & XNPU_CAP_AXI_DMA) {
		if (!pdev->dev.dma_mask)
			pdev->dev.dma_mask = &pdev->dev.coherent_dma_mask;
		ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
		if (ret)
			return dev_err_probe(&pdev->dev, ret,
					     "failed to set 32-bit DMA mask\n");
	}

	if (npu->irq >= 0) {
		ret = devm_request_irq(&pdev->dev, npu->irq, xnpu_irq,
				       0, dev_name(&pdev->dev), npu);
		if (ret)
			return ret;
		npu->capabilities |= XNPU_CAP_IRQ;
	}

	npu->miscdev.minor = MISC_DYNAMIC_MINOR;
	npu->miscdev.name = "xnpu";
	npu->miscdev.fops = &xnpu_fops;
	npu->miscdev.parent = &pdev->dev;

	ret = misc_register(&npu->miscdev);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, npu);
	dev_info(&pdev->dev,
		 "registered /dev/%s, irq=%d hw_abi=%u caps=0x%08x\n",
		 npu->miscdev.name, npu->irq, npu->hardware_abi,
		 npu->capabilities);
	return 0;
}

static int xnpu_remove(struct platform_device *pdev)
{
	struct xnpu *npu = platform_get_drvdata(pdev);

	misc_deregister(&npu->miscdev);
	mutex_lock(&npu->lock);
	xnpu_reset_device(npu);
	mutex_unlock(&npu->lock);
	return 0;
}

static const struct of_device_id xnpu_of_match[] = {
	{ .compatible = "xnpu" },
	{ }
};
MODULE_DEVICE_TABLE(of, xnpu_of_match);

static struct platform_driver xnpu_driver = {
	.probe = xnpu_probe,
	.remove = xnpu_remove,
	.driver = {
		.name = "xnpu",
		.of_match_table = xnpu_of_match,
	},
};
module_platform_driver(xnpu_driver);

MODULE_DESCRIPTION("XNPU neural-network accelerator");
MODULE_AUTHOR("NSCSCC team");
MODULE_LICENSE("GPL");
