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

#include "audio_coreaudio.h"
#include "driver/wivrn_session.h"
#include "os/os_time.h"
#include "util/u_logging.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <algorithm>
#include <cstdlib>
#include <mutex>

namespace wivrn
{
namespace
{

AudioObjectID translate_pid_to_process_object(pid_t pid)
{
	AudioObjectID process_obj = kAudioObjectUnknown;
	UInt32 size = sizeof(process_obj);
	AudioObjectPropertyAddress addr{
	        kAudioHardwarePropertyTranslatePIDToProcessObject,
	        kAudioObjectPropertyScopeGlobal,
	        kAudioObjectPropertyElementMain,
	};
	OSStatus err = AudioObjectGetPropertyData(
	        kAudioObjectSystemObject, &addr, sizeof(pid), &pid, &size, &process_obj);
	if (err != noErr || process_obj == kAudioObjectUnknown)
		return kAudioObjectUnknown;
	return process_obj;
}

NSString * get_tap_uuid(AudioObjectID tap_id)
{
	CFStringRef uid = nullptr;
	UInt32 size = sizeof(uid);
	AudioObjectPropertyAddress addr{
	        kAudioTapPropertyUID,
	        kAudioObjectPropertyScopeGlobal,
	        kAudioObjectPropertyElementMain,
	};
	OSStatus err = AudioObjectGetPropertyData(tap_id, &addr, 0, nullptr, &size, &uid);
	if (err != noErr || !uid)
		return nil;
	return (__bridge_transfer NSString *)uid;
}

struct coreaudio_device : public audio_device
{
	to_headset::audio_stream_description desc;
	wivrn_session & session;

	std::mutex tap_mutex;
	AudioObjectID tap_id = kAudioObjectUnknown;
	AudioObjectID aggregate_id = kAudioObjectUnknown;
	AudioDeviceIOProcID io_proc_id = nullptr;
	std::vector<uint8_t> io_buffer;
	bool capturing = false;
	pid_t tapped_pid = 0;
	pid_t pending_pid = 0;
	AudioObjectPropertyListenerBlock process_listener_block = nil;

	void install_process_listener();
	void remove_process_listener();
	void on_process_list_changed();

	to_headset::audio_stream_description description() const override
	{
		return desc;
	}

	void process_mic_data(wivrn::audio_data &&) override
	{
		// TODO: Add microphone support
	}

	void pause() override {}

	void resume() override
	{
		session.send_control(description());
	}

	void on_app_connected(pid_t pid) override;
	void on_app_disconnected(pid_t pid) override;

	bool setup_tap(pid_t pid);
	void teardown_tap();

	static OSStatus io_proc(
	        AudioObjectID inDevice,
	        const AudioTimeStamp * inNow,
	        const AudioBufferList * inInputData,
	        const AudioTimeStamp * inInputTime,
	        AudioBufferList * outOutputData,
	        const AudioTimeStamp * inOutputTime,
	        void * inClientData);

	coreaudio_device(
	        const std::string & source_name,
	        const std::string & source_description,
	        const std::string & sink_name,
	        const std::string & sink_description,
	        const wivrn::from_headset::headset_info_packet & info,
	        wivrn::wivrn_session & session);

	~coreaudio_device();
};

coreaudio_device::coreaudio_device(
        const std::string & source_name,
        const std::string & source_description,
        const std::string & sink_name,
        const std::string & sink_description,
        const wivrn::from_headset::headset_info_packet & info,
        wivrn::wivrn_session & session) :
        session(session)
{
	if (info.speaker)
	{
		desc.speaker = {
		        .num_channels = info.speaker->num_channels,
		        .sample_rate = info.speaker->sample_rate,
		};
	}

	const char * pid_env = std::getenv("WIVRN_AUDIO_PID");
	if (pid_env)
	{
		pid_t pid = static_cast<pid_t>(std::atoi(pid_env));
		if (pid > 0)
		{
			std::lock_guard lock(tap_mutex);
			U_LOG_I("CoreAudio: using explicit PID %d from WIVRN_AUDIO_PID", pid);
			if (!setup_tap(pid))
				U_LOG_W("CoreAudio: failed to tap PID %d, will retry on app connect", pid);
		}
	}

	U_LOG_I("CoreAudio audio device created, waiting for app to connect");
}

coreaudio_device::~coreaudio_device()
{
	remove_process_listener();
	teardown_tap();
}

void coreaudio_device::install_process_listener()
{
	if (process_listener_block)
		return;

	AudioObjectPropertyAddress addr{
	        kAudioHardwarePropertyProcessObjectList,
	        kAudioObjectPropertyScopeGlobal,
	        kAudioObjectPropertyElementMain,
	};

	process_listener_block = ^(UInt32, const AudioObjectPropertyAddress *) {
		on_process_list_changed();
	};

	OSStatus err = AudioObjectAddPropertyListenerBlock(
	        kAudioObjectSystemObject,
	        &addr,
	        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
	        process_listener_block);

	if (err != noErr)
	{
		U_LOG_W("CoreAudio: failed to install process list listener: %d", (int)err);
		process_listener_block = nil;
	}
}

void coreaudio_device::remove_process_listener()
{
	if (!process_listener_block)
		return;

	AudioObjectPropertyAddress addr{
	        kAudioHardwarePropertyProcessObjectList,
	        kAudioObjectPropertyScopeGlobal,
	        kAudioObjectPropertyElementMain,
	};

	AudioObjectRemovePropertyListenerBlock(
	        kAudioObjectSystemObject,
	        &addr,
	        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
	        process_listener_block);
	process_listener_block = nil;
}

void coreaudio_device::on_process_list_changed()
{
	std::lock_guard lock(tap_mutex);

	if (capturing || pending_pid == 0)
		return;

	U_LOG_W("CoreAudio: process list changed, retrying PID %d", pending_pid);

	if (setup_tap(pending_pid))
	{
		U_LOG_I("CoreAudio: audio capture started for PID %d (deferred)", pending_pid);
		pending_pid = 0;
		// Can't call remove_process_listener() here, we're inside the block callback
		// Subsequent calls will no-op since pending_pid == 0
	}
}

void coreaudio_device::on_app_connected(pid_t pid)
{
	std::lock_guard lock(tap_mutex);

	if (capturing)
	{
		U_LOG_I("CoreAudio: already capturing (PID %d), ignoring new PID %d", tapped_pid, pid);
		return;
	}

	if (!desc.speaker)
	{
		U_LOG_W("CoreAudio: headset did not report speaker capability");
		return;
	}

	U_LOG_I("CoreAudio: app connected with PID %d, setting up audio tap", pid);
	if (setup_tap(pid))
	{
		U_LOG_I("CoreAudio: audio capture started for PID %d", pid);
	}
	else
	{
		U_LOG_I("CoreAudio: PID %d not yet in audio process list, waiting for it", pid);
		pending_pid = pid;
		install_process_listener();
	}
}

void coreaudio_device::on_app_disconnected(pid_t pid)
{
	// Must remove listener before acquiring tap_mutex: RemovePropertyListenerBlock
	// waits for in-flight block executions, which also acquire tap_mutex
	remove_process_listener();

	std::lock_guard lock(tap_mutex);

	pending_pid = 0;

	if (!capturing || tapped_pid != pid)
		return;

	U_LOG_I("CoreAudio: app disconnected (PID %d), tearing down tap", pid);
	teardown_tap();
}

bool coreaudio_device::setup_tap(pid_t pid)
{
	@autoreleasepool
	{
		if (!desc.speaker)
			return false;

		AudioObjectID process_obj = translate_pid_to_process_object(pid);
		if (process_obj == kAudioObjectUnknown)
		{
			U_LOG_D("CoreAudio: PID %d not found in audio process list", pid);
			return false;
		}

		// Match tap mixdown mode to headset channel count
		CATapDescription * tap_desc;
		uint8_t headset_ch = desc.speaker->num_channels;
		if (headset_ch <= 1)
			tap_desc = [[CATapDescription alloc] initMonoMixdownOfProcesses:@[ @(process_obj) ]];
		else if (headset_ch <= 2)
			tap_desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(process_obj) ]];
		else
		{
			tap_desc = [[CATapDescription alloc] init];
			tap_desc.processes = @[ @(process_obj) ];
		}
		tap_desc.name = @"WiVRn Audio Tap";
		tap_desc.privateTap = YES;
		tap_desc.muteBehavior = CATapMuted;

		OSStatus err = AudioHardwareCreateProcessTap(tap_desc, &tap_id);
		if (err != noErr)
		{
			U_LOG_W("CoreAudio: AudioHardwareCreateProcessTap failed: %d", (int)err);
			tap_id = kAudioObjectUnknown;
			return false;
		}

		NSString * tap_uuid = get_tap_uuid(tap_id);
		if (!tap_uuid)
		{
			U_LOG_W("CoreAudio: failed to get tap UUID");
			AudioHardwareDestroyProcessTap(tap_id);
			tap_id = kAudioObjectUnknown;
			return false;
		}

		NSDictionary * agg_desc = @{
			@(kAudioAggregateDeviceUIDKey): [[NSUUID UUID] UUIDString],
			@(kAudioAggregateDeviceNameKey): @"WiVRn Aggregate",
			@(kAudioAggregateDeviceIsPrivateKey): @YES,
			@(kAudioAggregateDeviceTapListKey): @[ @{
				@(kAudioSubTapUIDKey): tap_uuid,
				@(kAudioSubTapDriftCompensationKey): @YES,
			} ],
		};

		err = AudioHardwareCreateAggregateDevice(
		        (__bridge CFDictionaryRef)agg_desc, &aggregate_id);
		if (err != noErr)
		{
			U_LOG_W("CoreAudio: AudioHardwareCreateAggregateDevice failed: %d", (int)err);
			AudioHardwareDestroyProcessTap(tap_id);
			tap_id = kAudioObjectUnknown;
			aggregate_id = kAudioObjectUnknown;
			return false;
		}

		err = AudioDeviceCreateIOProcID(aggregate_id, &coreaudio_device::io_proc, this, &io_proc_id);
		if (err != noErr)
		{
			U_LOG_W("CoreAudio: AudioDeviceCreateIOProcID failed: %d", (int)err);
			AudioHardwareDestroyAggregateDevice(aggregate_id);
			AudioHardwareDestroyProcessTap(tap_id);
			io_proc_id = nullptr;
			aggregate_id = kAudioObjectUnknown;
			tap_id = kAudioObjectUnknown;
			return false;
		}

		// Pre-allocate so the RT callback never hits malloc
		io_buffer.resize(4096 * desc.speaker->num_channels * sizeof(int16_t));

		err = AudioDeviceStart(aggregate_id, io_proc_id);
		if (err != noErr)
		{
			U_LOG_W("CoreAudio: AudioDeviceStart failed: %d", (int)err);
			AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
			AudioHardwareDestroyAggregateDevice(aggregate_id);
			AudioHardwareDestroyProcessTap(tap_id);
			io_proc_id = nullptr;
			aggregate_id = kAudioObjectUnknown;
			tap_id = kAudioObjectUnknown;
			return false;
		}

		tapped_pid = pid;
		capturing = true;
		U_LOG_I("CoreAudio: tap active for PID %d", pid);
		return true;
	}
}

void coreaudio_device::teardown_tap()
{
	if (io_proc_id && aggregate_id != kAudioObjectUnknown)
	{
		AudioDeviceStop(aggregate_id, io_proc_id);
		AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
		io_proc_id = nullptr;
	}
	if (aggregate_id != kAudioObjectUnknown)
	{
		AudioHardwareDestroyAggregateDevice(aggregate_id);
		aggregate_id = kAudioObjectUnknown;
	}
	if (tap_id != kAudioObjectUnknown)
	{
		AudioHardwareDestroyProcessTap(tap_id);
		tap_id = kAudioObjectUnknown;
	}
	capturing = false;
	tapped_pid = 0;
}

OSStatus coreaudio_device::io_proc(
        AudioObjectID inDevice,
        const AudioTimeStamp * inNow,
        const AudioBufferList * inInputData,
        const AudioTimeStamp * inInputTime,
        AudioBufferList * outOutputData,
        const AudioTimeStamp * inOutputTime,
        void * inClientData)
{
	auto self = static_cast<coreaudio_device *>(inClientData);

	if (!inInputData || inInputData->mNumberBuffers == 0)
		return noErr;

	// Tap delivers interleaved float32, headset expects interleaved S16.
	// For mono/stereo the CATapDescription mixdown guarantees src_ch == dst_ch.
	// For >2ch headsets the tap provides native device channels, which may differ
	const AudioBuffer & buf = inInputData->mBuffers[0];
	UInt32 src_ch = buf.mNumberChannels;
	UInt32 dst_ch = self->desc.speaker->num_channels;
	UInt32 num_frames = buf.mDataByteSize / (src_ch * sizeof(float));

	size_t out_bytes = num_frames * dst_ch * sizeof(int16_t);
	if (out_bytes > self->io_buffer.size())
		return noErr;

	auto * src = static_cast<const float *>(buf.mData);
	auto * dst = reinterpret_cast<int16_t *>(self->io_buffer.data());

	// Per-frame channel mapping: copy matching channels, zero-fill extras
	for (UInt32 f = 0; f < num_frames; f++)
	{
		for (UInt32 c = 0; c < dst_ch; c++)
		{
			float s = (c < src_ch) ? src[f * src_ch + c] : 0.0f;
			// Clamp and convert float [-1.0, 1.0] to signed 16-bit
			dst[f * dst_ch + c] = static_cast<int16_t>(std::clamp(s, -1.0f, 1.0f) * 32767.0f);
		}
	}

	try
	{
		self->session.send_control(audio_data{
		        .timestamp = self->session.get_offset().to_headset(os_monotonic_get_ns()),
		        .payload = std::span<uint8_t>(
		                self->io_buffer.data(),
		                out_bytes),
		});
	}
	catch (std::exception & e)
	{
		U_LOG_D("CoreAudio: failed to send audio data: %s", e.what());
	}

	return noErr;
}

} // namespace

std::unique_ptr<audio_device> create_coreaudio_handle(
        const std::string & source_name,
        const std::string & source_description,
        const std::string & sink_name,
        const std::string & sink_description,
        const wivrn::from_headset::headset_info_packet & info,
        wivrn_session & session)
{
	try
	{
		return std::make_unique<coreaudio_device>(
		        source_name, source_description, sink_name, sink_description, info, session);
	}
	catch (std::exception & e)
	{
		U_LOG_I("CoreAudio backend creation failed: %s", e.what());
		return nullptr;
	}
}
} // namespace wivrn
