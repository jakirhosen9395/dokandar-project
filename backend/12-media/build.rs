// Compiles proto/media.proto with tonic-build (shells out to protoc — installed in the build image).
// Generated module path follows the proto `package`: dokandar.media.v1
//   → tonic::include_proto!("dokandar.media.v1")
fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .compile_protos(&["proto/media.proto"], &["proto"])?;
    Ok(())
}
