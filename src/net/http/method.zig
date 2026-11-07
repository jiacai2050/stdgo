//! HTTP Methods conforming to Go's net/http.
pub const MethodGet = "GET";
pub const MethodHead = "HEAD";
pub const MethodPost = "POST";
pub const MethodPut = "PUT";
pub const MethodPatch = "PATCH";
pub const MethodDelete = "DELETE";
pub const MethodConnect = "CONNECT";
pub const MethodOptions = "OPTIONS";
pub const MethodTrace = "TRACE";

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,

    pub fn asString(self: Method) []const u8 {
        return @tagName(self);
    }
};
