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

#pragma once

#include "video_encoder.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>
#include <VideoToolbox/VideoToolbox.h>
#include <vector>
#include <vulkan/vulkan_raii.hpp>

namespace wivrn
{

struct wivrn_vk_bundle;

class video_encoder_videotoolbox : public video_encoder
{
	VTCompressionSessionRef vt_session = nullptr;
	bool is_hevc;

	wivrn_vk_bundle & vk;

	struct in_t
	{
		vk::raii::Image image = nullptr;
		IOSurfaceRef iosurface = nullptr;
		CVPixelBufferRef pixel_buffer = nullptr;
	};
	std::array<in_t, num_slots> in;

	// Encoded output accumulated by callback, consumed by encode()
	std::vector<uint8_t> encoded_output;
	bool encoded_is_keyframe = false;

	static void vt_encode_callback(
	        void * outputCallbackRefCon,
	        void * sourceFrameRefCon,
	        OSStatus status,
	        VTEncodeInfoFlags infoFlags,
	        CMSampleBufferRef sampleBuffer);

	void process_output(CMSampleBufferRef sampleBuffer);

public:
	video_encoder_videotoolbox(
	        wivrn_vk_bundle & vk,
	        const encoder_settings & settings,
	        uint8_t stream_idx);

	~video_encoder_videotoolbox();

	std::pair<bool, vk::Semaphore> present_image(
	        vk::Image y_cbcr,
	        bool transferred,
	        vk::raii::CommandBuffer & cmd_buf,
	        uint8_t slot,
	        uint64_t frame_index) override;

	std::optional<data> encode(uint8_t slot, uint64_t frame_index) override;
};

} // namespace wivrn
