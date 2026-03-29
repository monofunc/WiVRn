/*
 * WiVRn VR streaming
 * Copyright (C) 2026 Mono <81423605+monofunc@users.noreply.github.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#define VK_USE_PLATFORM_METAL_EXT

#include "encoder_settings.h"
#include "idr_handler.h"
#include "utils/wivrn_vk_bundle.h"
#include "video_encoder_videotoolbox.h"

#include <CoreMedia/CoreMedia.h>
#include <cassert>
#include <util/u_logging.h>

static const uint8_t kAnnexBStartCode[4] = {0, 0, 0, 1};

namespace wivrn
{

void video_encoder_videotoolbox::vt_encode_callback(
        void * outputCallbackRefCon,
        void * sourceFrameRefCon,
        OSStatus status,
        VTEncodeInfoFlags infoFlags,
        CMSampleBufferRef sampleBuffer)
{
	if (status != noErr || !sampleBuffer)
	{
		U_LOG_E("VideoToolbox encode callback error: %d", (int)status);
		return;
	}

	auto * self = static_cast<video_encoder_videotoolbox *>(outputCallbackRefCon);
	self->process_output(sampleBuffer);
}

void video_encoder_videotoolbox::process_output(CMSampleBufferRef sampleBuffer)
{
	CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);

	bool keyframe = false;
	CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
	if (attachments && CFArrayGetCount(attachments) > 0)
	{
		auto dict = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
		keyframe = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
	}

	encoded_is_keyframe = keyframe;

	if (keyframe)
	{
		size_t pset_count = 0;
		int nal_size_field = 0;

		if (is_hevc)
			CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, nullptr, nullptr, &pset_count, &nal_size_field);
		else
			CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, nullptr, nullptr, &pset_count, &nal_size_field);

		assert(nal_size_field == 4);

		for (size_t i = 0; i < pset_count; i++)
		{
			const uint8_t * pset = nullptr;
			size_t pset_size = 0;

			if (is_hevc)
				CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &pset, &pset_size, nullptr, nullptr);
			else
				CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &pset, &pset_size, nullptr, nullptr);

			encoded_output.insert(encoded_output.end(), kAnnexBStartCode, kAnnexBStartCode + 4);
			encoded_output.insert(encoded_output.end(), pset, pset + pset_size);
		}
	}

	CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
	size_t total_length = CMBlockBufferGetDataLength(block);

	// Copy AVCC data into encoded_output
	size_t base = encoded_output.size();
	encoded_output.resize(base + total_length);
	CMBlockBufferCopyDataBytes(block, 0, total_length, encoded_output.data() + base);

	// Convert AVCC length-prefixed NALs to Annex B start codes
	size_t offset = 0;
	while (offset + 4 <= total_length)
	{
		uint32_t nal_size = (uint32_t(encoded_output[base + offset]) << 24) |
		                    (uint32_t(encoded_output[base + offset + 1]) << 16) |
		                    (uint32_t(encoded_output[base + offset + 2]) << 8) |
		                    uint32_t(encoded_output[base + offset + 3]);
		if (nal_size == 0 || offset + 4 + nal_size > total_length)
			break;
		memcpy(encoded_output.data() + base + offset, kAnnexBStartCode, 4);
		offset += 4 + nal_size;
	}
}

video_encoder_videotoolbox::video_encoder_videotoolbox(
        wivrn_vk_bundle & vk,
        const encoder_settings & settings,
        uint8_t stream_idx) :
        video_encoder(stream_idx, settings, std::make_unique<default_idr_handler>(), true),
        vk(vk),
        is_hevc(settings.codec == h265)
{
	CMVideoCodecType codec_type = is_hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;

	// Set EnableLowLatencyRateControl in the encoder spec, not post-creation
	CFMutableDictionaryRef encoder_spec = CFDictionaryCreateMutable(
	        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(encoder_spec, CFSTR("EnableLowLatencyRateControl"), kCFBooleanTrue);

	// Tell VT we will provide IOSurface-backed BGRA pixel buffers
	NSDictionary * source_attrs = @{
		(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
		(NSString *)kCVPixelBufferWidthKey : @(extent.width),
		(NSString *)kCVPixelBufferHeightKey : @(extent.height),
		(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
	};

	OSStatus err = VTCompressionSessionCreate(
	        kCFAllocatorDefault,
	        extent.width,
	        extent.height,
	        codec_type,
	        encoder_spec,
	        (__bridge CFDictionaryRef)source_attrs,
	        nullptr,
	        vt_encode_callback,
	        this,
	        &vt_session);

	CFRelease(encoder_spec);

	if (err != noErr)
		throw std::runtime_error("VTCompressionSessionCreate failed: " + std::to_string(err));

	// Bitrate
	int64_t bitrate = settings.bitrate;
	CFNumberRef bitrate_ref = CFNumberCreate(nullptr, kCFNumberSInt64Type, &bitrate);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_AverageBitRate, bitrate_ref);
	CFRelease(bitrate_ref);

	// Frame rate hint
	float fps = settings.fps;
	CFNumberRef fps_ref = CFNumberCreate(nullptr, kCFNumberFloatType, &fps);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_ExpectedFrameRate, fps_ref);
	CFRelease(fps_ref);

	// IDR controlled by idr_handler, disable automatic keyframes
	int max_interval = INT32_MAX;
	CFNumberRef interval_ref = CFNumberCreate(nullptr, kCFNumberIntType, &max_interval);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, interval_ref);
	CFRelease(interval_ref);

	// Disallow frame reordering, one-in-one-out
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

	// No frame delay, callback fires before EncodeFrame returns
	int max_delay = 0;
	CFNumberRef max_delay_ref = CFNumberCreate(nullptr, kCFNumberIntType, &max_delay);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_MaxFrameDelayCount, max_delay_ref);
	CFRelease(max_delay_ref);

	// Prioritize speed over quality for streaming
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);

	// BT.709 color space (Quest decoder needs this for correct YUV->RGB)
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2);
	VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);

	VTCompressionSessionPrepareToEncodeFrames(vt_session);

	// Allocate shared IOSurface-backed images for each encoder slot
	for (auto & slot: in)
	{
		size_t bytes_per_row = extent.width * 4;
		size_t alloc_size = bytes_per_row * extent.height;
		NSDictionary * surface_props = @{
			(NSString *)kIOSurfaceWidth : @(extent.width),
			(NSString *)kIOSurfaceHeight : @(extent.height),
			(NSString *)kIOSurfaceBytesPerElement : @4,
			(NSString *)kIOSurfaceBytesPerRow : @(bytes_per_row),
			(NSString *)kIOSurfaceAllocSize : @(alloc_size),
			(NSString *)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
		};
		slot.iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)surface_props);
		if (!slot.iosurface)
			throw std::runtime_error("IOSurfaceCreate failed");

		NSDictionary * pb_attrs = @{
			(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
			(NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
		};
		CVReturn cv_ret = CVPixelBufferCreateWithIOSurface(
		        kCFAllocatorDefault,
		        slot.iosurface,
		        (__bridge CFDictionaryRef)pb_attrs,
		        &slot.pixel_buffer);
		if (cv_ret != kCVReturnSuccess)
			throw std::runtime_error("CVPixelBufferCreateWithIOSurface failed: " + std::to_string(cv_ret));

		vk::ImportMetalIOSurfaceInfoEXT import_info{
		        .ioSurface = slot.iosurface,
		};
		vk::ImageCreateInfo image_ci{
		        .pNext = &import_info,
		        .imageType = vk::ImageType::e2D,
		        .format = vk::Format::eB8G8R8A8Unorm,
		        .extent = {extent.width, extent.height, 1},
		        .mipLevels = 1,
		        .arrayLayers = 1,
		        .samples = vk::SampleCountFlagBits::e1,
		        .tiling = vk::ImageTiling::eOptimal,
		        .usage = vk::ImageUsageFlagBits::eTransferDst,
		        .sharingMode = vk::SharingMode::eExclusive,
		};
		slot.image = vk::raii::Image(vk.device, image_ci);
		// Memory is bound internally by ImportMetalIOSurfaceInfoEXT
	}
}

video_encoder_videotoolbox::~video_encoder_videotoolbox()
{
	if (vt_session)
	{
		VTCompressionSessionCompleteFrames(vt_session, kCMTimeInvalid);
		VTCompressionSessionInvalidate(vt_session);
		CFRelease(vt_session);
	}
	for (auto & slot: in)
	{
		if (slot.pixel_buffer)
			CVPixelBufferRelease(slot.pixel_buffer);
		if (slot.iosurface)
			CFRelease(slot.iosurface);
		// vk::raii cleans up slot.image
	}
}

std::pair<bool, vk::Semaphore> video_encoder_videotoolbox::present_image(
        vk::Image y_cbcr,
        bool transferred,
        vk::raii::CommandBuffer & cmd_buf,
        uint8_t slot,
        uint64_t frame_index)
{
	// Transition IOSurface-backed image to transfer dst
	vk::ImageMemoryBarrier2 barrier{
	        .srcStageMask = vk::PipelineStageFlagBits2::eNone,
	        .srcAccessMask = vk::AccessFlagBits2::eNone,
	        .dstStageMask = vk::PipelineStageFlagBits2::eTransfer,
	        .dstAccessMask = vk::AccessFlagBits2::eTransferWrite,
	        .oldLayout = vk::ImageLayout::eUndefined,
	        .newLayout = vk::ImageLayout::eTransferDstOptimal,
	        .image = *in[slot].image,
	        .subresourceRange = {
	                .aspectMask = vk::ImageAspectFlagBits::eColor,
	                .levelCount = 1,
	                .layerCount = 1,
	        },
	};
	cmd_buf.pipelineBarrier2(vk::DependencyInfo{
	        .imageMemoryBarrierCount = 1,
	        .pImageMemoryBarriers = &barrier,
	});

	// GPU-to-GPU copy within UMA, no readback
	cmd_buf.copyImage(
	        y_cbcr,
	        vk::ImageLayout::eTransferSrcOptimal,
	        *in[slot].image,
	        vk::ImageLayout::eTransferDstOptimal,
	        vk::ImageCopy{
	                .srcSubresource = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .layerCount = 1,
	                        .baseArrayLayer = stream_idx,
	                },
	                .srcOffset = {0, 0, 0},
	                .dstSubresource = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .layerCount = 1,
	                },
	                .dstOffset = {0, 0, 0},
	                .extent = {extent.width, extent.height, 1},
	        });

	return {false, nullptr};
}

std::optional<video_encoder::data> video_encoder_videotoolbox::encode(uint8_t slot, uint64_t frame_index)
{
	auto reconfig_bitrate = pending_bitrate.exchange(0);
	if (reconfig_bitrate)
	{
		int64_t br = static_cast<int64_t>(reconfig_bitrate);
		CFNumberRef ref = CFNumberCreate(nullptr, kCFNumberSInt64Type, &br);
		VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_AverageBitRate, ref);
		CFRelease(ref);
	}

	auto reconfig_fps = pending_framerate.exchange(0);
	if (reconfig_fps)
	{
		float fr = reconfig_fps;
		CFNumberRef ref = CFNumberCreate(nullptr, kCFNumberFloatType, &fr);
		VTSessionSetProperty(vt_session, kVTCompressionPropertyKey_ExpectedFrameRate, ref);
		CFRelease(ref);
	}

	// Reset output buffer, callback fills it during CompleteFrames
	encoded_output.clear();
	encoded_is_keyframe = false;

	CFDictionaryRef frame_props = nullptr;
	auto & idr_h = static_cast<default_idr_handler &>(*idr);
	auto frame_type = idr_h.get_type(frame_index);
	if (frame_type == default_idr_handler::frame_type::i)
	{
		CFStringRef keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
		CFTypeRef values[] = {kCFBooleanTrue};
		frame_props = CFDictionaryCreate(nullptr,
		                                 (const void **)keys,
		                                 (const void **)values,
		                                 1,
		                                 &kCFTypeDictionaryKeyCallBacks,
		                                 &kCFTypeDictionaryValueCallBacks);
	}

	CMTime pts = CMTimeMake(frame_index, 90);

	OSStatus err = VTCompressionSessionEncodeFrame(
	        vt_session, in[slot].pixel_buffer, pts, kCMTimeInvalid, frame_props, nullptr, nullptr);

	if (frame_props)
		CFRelease(frame_props);

	if (err != noErr)
	{
		U_LOG_E("VTCompressionSessionEncodeFrame failed: %d", (int)err);
		return {};
	}

	VTCompressionSessionCompleteFrames(vt_session, kCMTimeInvalid);

	if (encoded_output.empty())
		return {};

	// Move encoded data into a shared_ptr so it lives until the async sender is done
	auto output = std::make_shared<std::vector<uint8_t>>(std::move(encoded_output));

	return data{
	        .encoder = this,
	        .span = std::span<uint8_t>(output->data(), output->size()),
	        .mem = output,
	        .prefer_control = encoded_is_keyframe,
	};
}

} // namespace wivrn
