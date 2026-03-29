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

#include "bonjour_publisher.h"

#include <arpa/inet.h>
#include <iostream>
#include <stdexcept>

namespace wivrn
{

void bonjour_publisher::register_callback(
        DNSServiceRef sdRef,
        DNSServiceFlags flags,
        DNSServiceErrorType errorCode,
        const char * name,
        const char * regtype,
        const char * domain,
        void * context)
{
	if (errorCode == kDNSServiceErr_NoError)
		std::cerr << "Bonjour: registered as " << name << "." << regtype << domain << std::endl;
	else
		std::cerr << "Bonjour: registration failed, error " << errorCode << std::endl;
}

bonjour_publisher::bonjour_publisher(
        const std::string & name,
        const std::string & type,
        int port,
        const std::map<std::string, std::string> & txt)
{
	TXTRecordRef txt_record;
	TXTRecordCreate(&txt_record, 0, nullptr);
	for (const auto & [key, value]: txt)
	{
		TXTRecordSetValue(&txt_record,
		                  key.c_str(),
		                  value.size(),
		                  value.c_str());
	}

	DNSServiceErrorType err = DNSServiceRegister(
	        &service_ref,
	        0,
	        kDNSServiceInterfaceIndexAny,
	        name.c_str(),
	        type.c_str(),
	        nullptr,
	        nullptr,
	        htons(port),
	        TXTRecordGetLength(&txt_record),
	        TXTRecordGetBytesPtr(&txt_record),
	        register_callback,
	        this);

	TXTRecordDeallocate(&txt_record);

	if (err != kDNSServiceErr_NoError)
	{
		service_ref = nullptr;
		throw std::runtime_error("DNSServiceRegister failed, error " + std::to_string(err));
	}

	int fd = DNSServiceRefSockFD(service_ref);
	read_source = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_READ,
	        fd,
	        0,
	        dispatch_get_main_queue());

	DNSServiceRef ref = service_ref;
	dispatch_source_set_event_handler(read_source, ^{
	  DNSServiceProcessResult(ref);
	});

	dispatch_resume(read_source);
}

bonjour_publisher::~bonjour_publisher()
{
	if (read_source)
	{
		DNSServiceRef ref = service_ref;
		dispatch_source_set_cancel_handler(read_source, ^{
		  DNSServiceRefDeallocate(ref);
		});
		dispatch_source_cancel(read_source);
		dispatch_release(read_source);
	}
	else if (service_ref)
	{
		DNSServiceRefDeallocate(service_ref);
	}
}

} // namespace wivrn
