package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os/os2"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"

MAX_REQUEST_SIZE :: 64 * 1024 // 64KB limit
CRLF :: "\r\n"

HTTP_Response :: struct {
	headers: map[string]string, // 32 bytes
	body:    string, // 16 bytes
	status:  HTTP_STATUS_CODE, // 8 bytes
}
#assert(align_of(HTTP_Response) == 8)
#assert(size_of(HTTP_Response) == 56)

HTTP_STATUS_CODE :: enum {
	OK,
	CREATED,
	NOT_FOUND,
}
#assert(size_of(HTTP_STATUS_CODE) == 8)
#assert(align_of(HTTP_STATUS_CODE) == 8)

HTTP_METHOD :: enum {
	GET,
	POST,
	PUT,
	DELETE,
}

HEADER_CONTENT_TYPE :: "Content-Type"
HEADER_CONTENT_LENGTH :: "Content-Length"
HEADER_USER_AGENT :: "User-Agent"

to_http_response :: proc(response: HTTP_Response) -> []byte {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	// Status Line
	switch response.status {
	case .OK:
		strings.write_string(&sb, "HTTP/1.1 200 OK\r\n")
	case .CREATED:
		strings.write_string(&sb, "HTTP/1.1 201 Created\r\n")
	case .NOT_FOUND:
		strings.write_string(&sb, "HTTP/1.1 404 NOT FOUND\r\n")
	}

	// Headers
	for key, value in response.headers {
		fmt.sbprintf(&sb, "%s: %s\r\n", key, value)
	}

	// Empty Line
	strings.write_string(&sb, "\r\n")

	// Body
	if response.body != "" {
		strings.write_string(&sb, response.body)
	}

	s := strings.to_string(sb)
	fmt.println(s)

	result := make([]byte, len(s))
	copy(result, transmute([]byte)s)
	return result
}

HTTP_Request :: struct {
	method:   HTTP_METHOD,
	target:   string,
	protocol: string,
	headers:  map[string]string,
	body:     string,
}

parse_request :: proc(request: []byte, byte_len: int) -> HTTP_Request {
	request_string := string(request[:byte_len])
	lines, _ := strings.split(request_string, CRLF)
	defer delete(lines)

	first_line := lines[0]
	parts, _ := strings.split(first_line, " ")
	defer delete(parts)

	// if len(parts) != 3 do return
	method_str := parts[0]
	target := parts[1]
	protocol := parts[2]

	method: HTTP_METHOD
	switch method_str {
	case "GET":
		method = .GET
	case "POST":
		method = .POST
	case "PUT":
		method = .PUT
	case "DELETE":
		method = .DELETE
	case:
		fmt.eprintf("Unsupported method: %s\n", method_str)
		method = .GET
	}

	headers := make(map[string]string)
	body_index := 0
	for i := 1; i < len(lines); i += 1 {
		if lines[i] == "" {
			body_index = i + 1
			break
		}

		header_parts, err := strings.split(lines[i], ": ")
		if err != nil {
			continue
		}

		key := header_parts[0]
		value := header_parts[1]
		headers[key] = value
	}

	body := lines[body_index]
	fmt.println("body", body)

	return HTTP_Request {
		method = method,
		target = target,
		protocol = protocol,
		headers = headers,
		body = body,
	}
}

Thread_Data :: struct {
	tcp_socket: net.TCP_Socket,
	file_dir:   Maybe(string),
}

thread_proc :: proc(d: Thread_Data) {
	defer net.close(d.tcp_socket)
	fmt.println("Thread starting")

	request_byte := make([]byte, MAX_REQUEST_SIZE)
	defer delete(request_byte)

	bytes_read, rerr := net.recv_tcp(d.tcp_socket, request_byte)
	if rerr != nil {
		fmt.println("Error receiving connection: ", rerr)
		os2.exit(1)
	}
	fmt.println("Request:")
	fmt.println(string(request_byte[:bytes_read]))

	request := parse_request(request_byte, bytes_read)
	defer delete(request.headers)

	if request.method == .GET && request.target == "/" {
		net.send_tcp(d.tcp_socket, to_http_response(HTTP_Response{status = .OK}))
	} else if request.method == .GET && strings.has_prefix(request.target, "/echo/") {
		content := strings.trim_prefix(request.target, "/echo/")

		headers := make(map[string]string)
		headers[HEADER_CONTENT_TYPE] = "text/plain"
		content_length: [4]byte
		headers[HEADER_CONTENT_LENGTH] = strconv.itoa(content_length[:], len(content))
		defer delete(headers)

		net.send_tcp(
			d.tcp_socket,
			to_http_response(HTTP_Response{status = .OK, headers = headers, body = content}),
		)
	} else if request.method == .GET && request.target == "/user-agent" {
		user_agent := request.headers[HEADER_USER_AGENT]
		net.send_tcp(
			d.tcp_socket,
			to_http_response(HTTP_Response{status = .OK, body = user_agent}),
		)
	} else if request.method == .GET && strings.has_prefix(request.target, "/files/") {
		filename := strings.trim_prefix(request.target, "/files/")
		if file_dir, has_value := d.file_dir.?; has_value {
			file_path, err := strings.concatenate({file_dir, filename})
			assert(err == nil)
			content, rerr := os2.read_entire_file_from_path(file_path, context.allocator)
			if rerr != nil {
				if rerr == os2.General_Error.Not_Exist {
					net.send_tcp(
						d.tcp_socket,
						to_http_response(HTTP_Response{status = .NOT_FOUND}),
					)
				}
			} else {
				headers := make(map[string]string)
				headers[HEADER_CONTENT_TYPE] = "application/octet-stream"
				content_length: [4]byte
				headers[HEADER_CONTENT_LENGTH] = strconv.itoa(content_length[:], len(content))
				defer delete(headers)

				net.send_tcp(
					d.tcp_socket,
					to_http_response(HTTP_Response{status = .OK, body = string(content)}),
				)
			}
		} else {
			net.send_tcp(d.tcp_socket, to_http_response(HTTP_Response{status = .NOT_FOUND}))
		}
	} else if request.method == .POST && strings.has_prefix(request.target, "/files/") {
		filename := strings.trim_prefix(request.target, "/files/")
		if file_dir, has_value := d.file_dir.?; has_value {
			file_path, err := strings.concatenate({file_dir, filename})
			assert(err == nil)

			werr := os2.write_entire_file(file_path, transmute([]u8)request.body)
			assert(werr == nil)

			net.send_tcp(d.tcp_socket, to_http_response(HTTP_Response{status = .CREATED}))
		} else {
			net.send_tcp(d.tcp_socket, to_http_response(HTTP_Response{status = .NOT_FOUND}))
		}

	} else {
		net.send_tcp(d.tcp_socket, to_http_response(HTTP_Response{status = .NOT_FOUND}))
	}

	fmt.println("Thread finishing")
}

main :: proc() {
	fmt.println(os2.args)
	args := os2.args
	file_dir: Maybe(string)

	if len(args) > 1 {
		if args[1] == "--directory" {
			file_dir = args[2]
			fmt.println("Directory set to: ", file_dir)
		}
	}

	socket, lerr := net.listen_tcp(
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = 4221},
	)
	defer net.close(socket)
	if lerr != nil {
		fmt.println("Failed to bind to port 4221")
		os2.exit(1)
	}

	for {
		tcp_socket, _, aerr := net.accept_tcp(socket)
		if aerr != nil {
			fmt.println("Error accepting connection: ", aerr)
			os2.exit(1)
		}

		d := Thread_Data {
			tcp_socket = tcp_socket,
			file_dir   = file_dir,
		}

		t := thread.create_and_start_with_poly_data(d, thread_proc, nil, .Normal, true)
		assert(t != nil)
	}
}
