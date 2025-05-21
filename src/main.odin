package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os/os2"
import "core:strconv"
import "core:strings"

CRLF :: "\r\n"

HTTP_Response :: struct {
	headers: HTTP_HEADERS, // 32 bytes
	body:    string, // 16 bytes
	status:  HTTP_STATUS_CODE, // 8 bytes
}
#assert(align_of(HTTP_Response) == 8)
#assert(size_of(HTTP_Response) == 56)

HTTP_STATUS_CODE :: enum {
	OK,
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

HTTP_HEADERS :: map[string]string
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
	path:     string,
	protocol: string,
	headers:  HTTP_HEADERS,
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
	path := parts[1]
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
	for i := 1; i < len(lines); i += 1 {
		if lines[i] == "" {
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

	return HTTP_Request{method = method, path = path, protocol = protocol, headers = headers}
}

main :: proc() {
	socket, lerr := net.listen_tcp(
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = 4221},
	)
	defer net.close(socket)
	if lerr != nil {
		fmt.println("Failed to bind to port 4221")
		os2.exit(1)
	}

	tcp_socket, _, aerr := net.accept_tcp(socket)
	if aerr != nil {
		fmt.println("Error accepting connection: ", aerr)
		os2.exit(1)
	}
	defer net.close(tcp_socket)

	request_byte := make([]byte, 1024)

	bytes_read, rerr := net.recv_tcp(tcp_socket, request_byte)
	if rerr != nil {
		fmt.println("Error receiving connection: ", rerr)
		os2.exit(1)
	}
	fmt.println("Request:")
	fmt.println(string(request_byte[:bytes_read]))

	request := parse_request(request_byte, bytes_read)
	defer delete(request.headers)

	if request.path == "/" {
		net.send_tcp(tcp_socket, to_http_response(HTTP_Response{status = .OK}))
	} else if strings.has_prefix(request.path, "/echo/") {
		content := strings.trim_prefix(request.path, "/echo/")

		headers := make(map[string]string)
		headers[HEADER_CONTENT_TYPE] = "text/plain"
		content_length: [4]byte
		headers[HEADER_CONTENT_LENGTH] = strconv.itoa(content_length[:], len(content))
		defer delete(headers)

		net.send_tcp(
			tcp_socket,
			to_http_response(HTTP_Response{status = .OK, headers = headers, body = content}),
		)
	} else if request.path == "/user-agent" {
		user_agent := request.headers[HEADER_USER_AGENT]
		net.send_tcp(tcp_socket, to_http_response(HTTP_Response{status = .OK, body = user_agent}))
	} else {
		net.send_tcp(tcp_socket, to_http_response(HTTP_Response{status = .NOT_FOUND}))
	}
}
