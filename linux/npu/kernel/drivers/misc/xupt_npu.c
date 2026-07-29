// SPDX-License-Identifier: GPL-2.0
/*
 * XUPT Chiplab neural-network accelerator driver
 */

#include <linux/atomic.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include <linux/xupt_npu.h>

#define XUPT_NPU_REG_CTRL		0x0000
#define XUPT_NPU_REG_STATUS		0x0004
#define XUPT_NPU_REG_FRAME_COUNT	0x000c
#define XUPT_NPU_REG_BBOX0		0x0010
#define XUPT_NPU_REG_BBOX1		0x0014
#define XUPT_NPU_REG_IRQ_STATUS		0x0018
#define XUPT_NPU_REG_IRQ_CLEAR		0x001c
#define XUPT_NPU_REG_PERF_CYCLES	0x0028
#define XUPT_NPU_REG_LAYER_COUNT	0x0034
#define XUPT_NPU_REG_DESC_CTRL		0x0038
#define XUPT_NPU_REG_DESC_STATUS	0x003c
#define XUPT_NPU_FRAME_MEM_BASE		0x1000
#define XUPT_NPU_DESC_RAM_BASE		0x6000

#define XUPT_NPU_CTRL_START		BIT(0)
#define XUPT_NPU_CTRL_SOFT_RESET	BIT(1)
#define XUPT_NPU_CTRL_IRQ_ENABLE	BIT(2)
#define XUPT_NPU_CTRL_CLEAR_FRAME	BIT(3)
#define XUPT_NPU_CTRL_CLEAR_STATUS	BIT(4)

#define XUPT_NPU_STATUS_BUSY		BIT(0)
#define XUPT_NPU_STATUS_DONE		BIT(1)
#define XUPT_NPU_STATUS_ERROR		BIT(2)
#define XUPT_NPU_STATUS_FRAME_FULL	BIT(3)
#define XUPT_NPU_DESC_ENABLE		BIT(0)
#define XUPT_NPU_DESC_READY		BIT(0)
#define XUPT_NPU_DESC_ERROR		BIT(1)
#define XUPT_NPU_BBOX_VALID		BIT(8)

struct xupt_npu {
	void __iomem *base;
	struct device *dev;
	struct miscdevice miscdev;
	struct completion completion;
	struct mutex lock;
	atomic_t opened;
	int irq;
	bool run_uses_irq;
};

static inline u32 xupt_npu_read(struct xupt_npu *npu, u32 offset)
{
	return readl(npu->base + offset);
}

static inline void xupt_npu_write(struct xupt_npu *npu, u32 offset, u32 value)
{
	writel(value, npu->base + offset);
}

static irqreturn_t xupt_npu_irq(int irq, void *data)
{
	struct xupt_npu *npu = data;

	if (!(xupt_npu_read(npu, XUPT_NPU_REG_IRQ_STATUS) & BIT(0)))
		return IRQ_NONE;

	xupt_npu_write(npu, XUPT_NPU_REG_IRQ_CLEAR, BIT(0));
	complete(&npu->completion);
	return IRQ_HANDLED;
}

static int xupt_npu_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct xupt_npu *npu = container_of(misc, struct xupt_npu, miscdev);

	if (atomic_cmpxchg(&npu->opened, 0, 1))
		return -EBUSY;

	file->private_data = npu;
	return nonseekable_open(inode, file);
}

static int xupt_npu_release(struct inode *inode, struct file *file)
{
	struct xupt_npu *npu = file->private_data;

	atomic_set(&npu->opened, 0);
	return 0;
}

static void xupt_npu_reset(struct xupt_npu *npu)
{
	reinit_completion(&npu->completion);
	npu->run_uses_irq = false;
	xupt_npu_write(npu, XUPT_NPU_REG_CTRL, XUPT_NPU_CTRL_SOFT_RESET);
	udelay(1);
	xupt_npu_write(npu, XUPT_NPU_REG_IRQ_CLEAR, BIT(0));
}

static int xupt_npu_load_descriptors(
	struct xupt_npu *npu, const struct xupt_npu_descriptors *request)
{
	size_t bytes;
	u32 *descriptors;
	u32 status;
	unsigned int layer;
	unsigned int word;
	int ret;

	if (!request->count || request->count > XUPT_NPU_MAX_LAYERS ||
	    request->reserved)
		return -EINVAL;
	if (xupt_npu_read(npu, XUPT_NPU_REG_STATUS) & XUPT_NPU_STATUS_BUSY)
		return -EBUSY;

	bytes = request->count * XUPT_NPU_DESC_WORDS * sizeof(u32);
	descriptors = memdup_user(u64_to_user_ptr(request->data), bytes);
	if (IS_ERR(descriptors))
		return PTR_ERR(descriptors);

	xupt_npu_write(npu, XUPT_NPU_REG_DESC_CTRL, XUPT_NPU_DESC_ENABLE);
	for (layer = 0; layer < request->count; ++layer) {
		for (word = 0; word < XUPT_NPU_DESC_WORDS; ++word) {
			u32 offset = XUPT_NPU_DESC_RAM_BASE +
				(layer * XUPT_NPU_DESC_WORDS + word) * sizeof(u32);

			xupt_npu_write(npu, offset,
				       descriptors[layer * XUPT_NPU_DESC_WORDS + word]);
		}
	}
	xupt_npu_write(npu, XUPT_NPU_REG_LAYER_COUNT, request->count);

	ret = readl_poll_timeout(npu->base + XUPT_NPU_REG_DESC_STATUS,
				 status,
				 status & (XUPT_NPU_DESC_READY |
					   XUPT_NPU_DESC_ERROR),
				 1, 10000);
	kfree(descriptors);
	if (ret)
		return ret;
	if (status & XUPT_NPU_DESC_ERROR)
		return -EIO;
	return 0;
}

static ssize_t xupt_npu_file_write(struct file *file,
				   const char __user *buffer,
				   size_t count, loff_t *position)
{
	struct xupt_npu *npu = file->private_data;
	u8 *frame;
	u32 status;
	unsigned int offset;
	int ret = 0;

	if (count != XUPT_NPU_FRAME_BYTES)
		return -EINVAL;

	frame = memdup_user(buffer, count);
	if (IS_ERR(frame))
		return PTR_ERR(frame);

	mutex_lock(&npu->lock);
	status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
	if (status & XUPT_NPU_STATUS_BUSY) {
		ret = -EBUSY;
		goto out;
	}

	xupt_npu_write(npu, XUPT_NPU_REG_CTRL,
		       XUPT_NPU_CTRL_CLEAR_FRAME | XUPT_NPU_CTRL_CLEAR_STATUS);
	for (offset = 0; offset < XUPT_NPU_FRAME_BYTES; offset += sizeof(u32)) {
		u32 value = (u32)frame[offset] |
			((u32)frame[offset + 1] << 8) |
			((u32)frame[offset + 2] << 16) |
			((u32)frame[offset + 3] << 24);

		xupt_npu_write(npu, XUPT_NPU_FRAME_MEM_BASE + offset, value);
	}

	status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
	if (xupt_npu_read(npu, XUPT_NPU_REG_FRAME_COUNT) !=
	    XUPT_NPU_FRAME_BYTES ||
	    !(status & XUPT_NPU_STATUS_FRAME_FULL))
		ret = -EIO;
out:
	mutex_unlock(&npu->lock);
	kfree(frame);
	return ret ? ret : count;
}

static int xupt_npu_start(struct xupt_npu *npu,
			  const struct xupt_npu_run *run)
{
	u32 control = XUPT_NPU_CTRL_START;
	u32 status;

	if (run->reserved || run->flags & ~XUPT_NPU_RUN_USE_IRQ)
		return -EINVAL;
	if ((run->flags & XUPT_NPU_RUN_USE_IRQ) && npu->irq < 0)
		return -ENXIO;

	status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
	if (status & XUPT_NPU_STATUS_BUSY)
		return -EBUSY;
	if (!(status & XUPT_NPU_STATUS_FRAME_FULL))
		return -ENODATA;

	reinit_completion(&npu->completion);
	xupt_npu_write(npu, XUPT_NPU_REG_IRQ_CLEAR, BIT(0));
	xupt_npu_write(npu, XUPT_NPU_REG_CTRL, XUPT_NPU_CTRL_CLEAR_STATUS);

	npu->run_uses_irq = run->flags & XUPT_NPU_RUN_USE_IRQ;
	if (npu->run_uses_irq)
		control |= XUPT_NPU_CTRL_IRQ_ENABLE;
	xupt_npu_write(npu, XUPT_NPU_REG_CTRL, control);

	status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
	if (!(status & (XUPT_NPU_STATUS_BUSY | XUPT_NPU_STATUS_DONE)))
		return -EIO;
	return 0;
}

static int xupt_npu_wait(struct xupt_npu *npu,
			 struct xupt_npu_result *result)
{
	unsigned long timeout;
	unsigned long deadline;
	u32 bbox0;
	u32 bbox1;
	u32 status;
	long wait_ret;

	if (!result->timeout_ms)
		return -EINVAL;

	timeout = msecs_to_jiffies(result->timeout_ms);
	if (npu->run_uses_irq) {
		wait_ret = wait_for_completion_interruptible_timeout(
			&npu->completion, timeout);
		if (wait_ret < 0)
			return wait_ret;
		if (!wait_ret)
			return -ETIMEDOUT;
	} else {
		deadline = jiffies + timeout;
		do {
			status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
			if (status & (XUPT_NPU_STATUS_DONE |
				      XUPT_NPU_STATUS_ERROR))
				break;
			usleep_range(100, 200);
		} while (time_before(jiffies, deadline));
	}

	status = xupt_npu_read(npu, XUPT_NPU_REG_STATUS);
	result->status = status;
	result->perf_cycles =
		xupt_npu_read(npu, XUPT_NPU_REG_PERF_CYCLES);
	bbox0 = xupt_npu_read(npu, XUPT_NPU_REG_BBOX0);
	bbox1 = xupt_npu_read(npu, XUPT_NPU_REG_BBOX1);
	result->bbox[0] = bbox0;
	result->bbox[1] = bbox0 >> 8;
	result->bbox[2] = bbox0 >> 16;
	result->bbox[3] = bbox0 >> 24;
	result->bbox[4] = bbox1;
	result->valid = !!(bbox1 & XUPT_NPU_BBOX_VALID);
	result->frame_id = bbox1 >> 16;

	if (status & XUPT_NPU_STATUS_ERROR)
		return -EIO;
	if (!(status & XUPT_NPU_STATUS_DONE))
		return -ETIMEDOUT;
	return 0;
}

static long xupt_npu_ioctl(struct file *file, unsigned int command,
			   unsigned long argument)
{
	struct xupt_npu *npu = file->private_data;
	void __user *user_argument = (void __user *)argument;
	struct xupt_npu_descriptors descriptors;
	struct xupt_npu_result result;
	struct xupt_npu_info info;
	struct xupt_npu_run run;
	int ret = 0;

	if (_IOC_TYPE(command) != XUPT_NPU_IOC_MAGIC)
		return -ENOTTY;

	mutex_lock(&npu->lock);
	switch (command) {
	case XUPT_NPU_IOC_GET_INFO:
		memset(&info, 0, sizeof(info));
		info.abi_version = XUPT_NPU_ABI_VERSION;
		info.frame_width = XUPT_NPU_FRAME_WIDTH;
		info.frame_height = XUPT_NPU_FRAME_HEIGHT;
		info.frame_bytes = XUPT_NPU_FRAME_BYTES;
		info.max_layers = XUPT_NPU_MAX_LAYERS;
		info.has_irq = npu->irq >= 0;
		if (copy_to_user(user_argument, &info, sizeof(info)))
			ret = -EFAULT;
		break;
	case XUPT_NPU_IOC_RESET:
		xupt_npu_reset(npu);
		break;
	case XUPT_NPU_IOC_LOAD_DESCRIPTORS:
		if (copy_from_user(&descriptors, user_argument,
				   sizeof(descriptors))) {
			ret = -EFAULT;
			break;
		}
		ret = xupt_npu_load_descriptors(npu, &descriptors);
		break;
	case XUPT_NPU_IOC_RUN:
		if (copy_from_user(&run, user_argument, sizeof(run))) {
			ret = -EFAULT;
			break;
		}
		ret = xupt_npu_start(npu, &run);
		break;
	case XUPT_NPU_IOC_WAIT:
		if (copy_from_user(&result, user_argument, sizeof(result))) {
			ret = -EFAULT;
			break;
		}
		ret = xupt_npu_wait(npu, &result);
		if (!ret && copy_to_user(user_argument, &result, sizeof(result)))
			ret = -EFAULT;
		break;
	default:
		ret = -ENOTTY;
		break;
	}
	mutex_unlock(&npu->lock);
	return ret;
}

static const struct file_operations xupt_npu_fops = {
	.owner = THIS_MODULE,
	.open = xupt_npu_open,
	.release = xupt_npu_release,
	.write = xupt_npu_file_write,
	.unlocked_ioctl = xupt_npu_ioctl,
	.llseek = no_llseek,
};

static int xupt_npu_probe(struct platform_device *pdev)
{
	struct xupt_npu *npu;
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

	if (npu->irq >= 0) {
		ret = devm_request_irq(&pdev->dev, npu->irq, xupt_npu_irq,
				       0, dev_name(&pdev->dev), npu);
		if (ret)
			return ret;
	}

	npu->miscdev.minor = MISC_DYNAMIC_MINOR;
	npu->miscdev.name = "xupt-npu";
	npu->miscdev.fops = &xupt_npu_fops;
	npu->miscdev.parent = &pdev->dev;

	ret = misc_register(&npu->miscdev);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, npu);
	xupt_npu_reset(npu);
	dev_info(&pdev->dev, "registered /dev/%s, irq=%d\n",
		 npu->miscdev.name, npu->irq);
	return 0;
}

static int xupt_npu_remove(struct platform_device *pdev)
{
	struct xupt_npu *npu = platform_get_drvdata(pdev);

	misc_deregister(&npu->miscdev);
	return 0;
}

static const struct of_device_id xupt_npu_of_match[] = {
	{ .compatible = "xupt,npu-v1" },
	{ }
};
MODULE_DEVICE_TABLE(of, xupt_npu_of_match);

static struct platform_driver xupt_npu_driver = {
	.probe = xupt_npu_probe,
	.remove = xupt_npu_remove,
	.driver = {
		.name = "xupt-npu",
		.of_match_table = xupt_npu_of_match,
	},
};
module_platform_driver(xupt_npu_driver);

MODULE_DESCRIPTION("XUPT Chiplab neural-network accelerator");
MODULE_AUTHOR("XUPT NSCSCC team");
MODULE_LICENSE("GPL");
