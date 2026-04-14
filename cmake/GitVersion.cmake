if (NOT GIT_DESC)
	execute_process(
		COMMAND ${GIT_EXECUTABLE} describe --tags --always
		OUTPUT_VARIABLE GIT_DESC
		RESULT_VARIABLE GIT_DESC_RESULT
		ERROR_QUIET
		WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
	string(STRIP "${GIT_DESC}" GIT_DESC)
	if (GIT_DESC)
		message(STATUS "Setting version to ${GIT_DESC} from git")
	else()
		message(WARNING "GIT_DESC cannot be inferred from .git and was not provided at build time, using 'unknown'")
		set(GIT_DESC "unknown")
	endif()
else()
	message(STATUS "Setting version to ${GIT_DESC} from parameters")
endif()

if (NOT GIT_COMMIT)
	execute_process(
		COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
		OUTPUT_VARIABLE GIT_COMMIT
		ERROR_QUIET
		WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
	string(STRIP "${GIT_COMMIT}" GIT_COMMIT)
	if (NOT GIT_COMMIT)
		message(WARNING "GIT_COMMIT cannot be inferred from .git and was not provided at build time, using 'unknown'")
		set(GIT_COMMIT "unknown")
	endif()
endif()

message(STATUS "Setting commit to ${GIT_COMMIT}")

configure_file(${INPUT_FILE} ${OUTPUT_FILE})
configure_file(${INPUT_FILE_1} ${OUTPUT_FILE_1})
