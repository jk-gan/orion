package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os/os2"
import "core:strconv"
import "core:strings"

CRLF :: "\r\n"

HTTP_RESPONSE :: struct {
	headers: HTTP_HEADERS, // 32 bytes
	body:    string, // 16 bytes
	status:  HTTP_STATUS_CODE, // 8 bytes
}
#assert(align_of(HTTP_RESPONSE) == 8)
#assert(size_of(HTTP_RESPONSE) == 56)

HTTP_STATUS_CODE :: enum {
	OK,
	NOT_FOUND,
}
#assert(size_of(HTTP_STATUS_CODE) == 8)
#assert(align_of(HTTP_STATUS_CODE) == 8)

HTTP_HEADERS :: map[string]string
HEADER_CONTENT_TYPE :: "Content-Type"
HEADER_CONTENT_LENGTH :: "Content-Length"

to_http_response :: proc(response: HTTP_RESPONSE) -> []byte {
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

	return transmute([]byte)string(strings.to_string(sb))
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

	request := make([]byte, 1024)
	defer delete(request)

	bytes_read, rerr := net.recv_tcp(tcp_socket, request)
	if rerr != nil {
		fmt.println("Error receiving connection: ", rerr)
		os2.exit(1)
	}
	fmt.println("Request:")
	fmt.println(string(request[:bytes_read]))

	request_string := string(request[:bytes_read])
	lines, _ := strings.split(request_string, CRLF)
	defer delete(lines)

	first_line := lines[0]
	parts, _ := strings.split(first_line, " ")
	defer delete(parts)

	if len(parts) != 3 do return
	method := parts[0]
	path := parts[1]
	protocol := parts[2]

	if path == "/" {
		net.send_tcp(tcp_socket, to_http_response(HTTP_RESPONSE{status = .OK}))
	} else if strings.has_prefix(path, "/echo/") {
		content := strings.trim_prefix(path, "/echo/")

		headers := make(map[string]string)
		headers[HEADER_CONTENT_TYPE] = "text/plain"
		content_length: [4]byte
		headers[HEADER_CONTENT_LENGTH] = strconv.itoa(content_length[:], len(content))
		defer delete(headers)

		net.send_tcp(
			tcp_socket,
			to_http_response(HTTP_RESPONSE{status = .OK, headers = headers, body = content}),
		)
	} else {
		net.send_tcp(tcp_socket, to_http_response(HTTP_RESPONSE{status = .NOT_FOUND}))
	}
}
