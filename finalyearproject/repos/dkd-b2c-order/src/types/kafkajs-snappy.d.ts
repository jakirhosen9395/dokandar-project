declare module "kafkajs-snappy" {
  const codec: () => { compress(encoder: { buffer: Buffer }): Promise<Buffer>; decompress(buffer: Buffer): Promise<Buffer> };
  export default codec;
}
