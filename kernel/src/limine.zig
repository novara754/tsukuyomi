fn request_id(comptime first: u64, comptime second: u64) [4]u64 {
    return [4]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, first, second };
}

pub export var BASE_REVISION linksection(".requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 };

// fn Request(id: [2]u64, comptime RequestData: type, comptime ResponseData: type) type {
//     const CommonResponseFields = @typeInfo(struct {
//         revision: u64,
//     }).@"struct".fields;

//     const Response = @Type(.{
//         .@"struct" = .{
//             .layout = .@"packed",
//             .backing_integer = u64,
//             .fields = @typeInfo(ResponseData).@"struct".fields ++ CommonResponseFields,
//             .decls = &.{},
//             .is_tuple = false,
//         },
//     });

//     const CommonFields = @typeInfo(struct {
//         id: [4]u64 = request_id(id),
//         revision: u64 = 0,
//         response: ?*Response = null,
//     }).@"struct".fields;

//     return @Type(.{
//         .@"struct" = .{
//             .layout = .@"packed",
//             .backing_integer = u64,
//             .fields = @typeInfo(RequestData).@"struct".fields ++ CommonFields,
//             .decls = &.{},
//             .is_tuple = false,
//         },
//     });
// }

const HHDMResponse = extern struct {
    revision: u64,
    offset: u64,
};

const HHDMRequest = extern struct {
    id: [4]u64 = request_id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HHDMResponse = null,
};

pub export var HHDM = HHDMRequest{};
