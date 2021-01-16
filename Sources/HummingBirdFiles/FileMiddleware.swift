import HummingBird
import NIO

public struct FileMiddleware: Middleware {
    let rootFolder: String
    let fileIO: NonBlockingFileIO

    public init(_ rootFolder: String = "public", app: Application) {
        var rootFolder = rootFolder
        if rootFolder.last == "/" {
            rootFolder = String(rootFolder.dropLast())
        }
        self.rootFolder = rootFolder
        self.fileIO = .init(threadPool: app.threadPool)
    }

    public func apply(to request: Request, next: RequestResponder) -> EventLoopFuture<Response> {
        // if next responder returns a 404 then check if file exists
        return next.respond(to: request).flatMapError { error in
            guard let httpError = error as? HTTPError, httpError.status == .notFound else {
                return request.eventLoop.makeFailedFuture(error)
            }

            let path = rootFolder + request.uri.path

            switch request.method {
            case .GET:
                return fileIO.openFile(path: path, eventLoop: request.eventLoop).flatMap { handle, region in
                    request.logger.debug("[FileMiddleware] GET", metadata: ["file": .string(path)])
                    let futureResponse: EventLoopFuture<Response>
                    if region.readableBytes > 32 * 1024 {
                        futureResponse = streamFile(for: request, handle: handle, region: region)
                    } else {
                        futureResponse = loadFile(for: request, handle: handle, region: region)
                    }
                    return futureResponse
                }.flatMapErrorThrowing { _ in
                    throw error
                }
            case .HEAD:
                return fileIO.openFile(path: path, eventLoop: request.eventLoop).flatMap { handle, region in
                    request.logger.debug("[FileMiddleware] HEAD", metadata: ["file": .string(path)])
                    let headers: HTTPHeaders = ["content-length": region.readableBytes.description]
                    let response = Response(status: .ok, headers: headers, body: .empty)
                    try? handle.close()
                    return request.eventLoop.makeSucceededFuture(response)
                }.flatMapErrorThrowing { _ in
                    throw error
                }
            default:
                return request.eventLoop.makeFailedFuture(error)
            }
        }
    }

    public func loadFile(for request: Request, handle: NIOFileHandle, region: FileRegion) -> EventLoopFuture<Response> {
        return self.fileIO.read(fileHandle: handle, byteCount: region.readableBytes, allocator: request.allocator, eventLoop: request.eventLoop).map { buffer in
            return Response(status: .ok, headers: [:], body: .byteBuffer(buffer))
        }
        .always { _ in
            try? handle.close()
        }
    }

    public func streamFile(for request: Request, handle: NIOFileHandle, region: FileRegion) -> EventLoopFuture<Response> {
        let fileStreamer = FileStreamer(handle: handle, fileSize: region.readableBytes, fileIO: self.fileIO, allocator: request.allocator)
        let response = Response(status: .ok, headers: [:], body: .stream(fileStreamer))
        return request.eventLoop.makeSucceededFuture(response)
    }

    // class used to stream files
    class FileStreamer: ResponseBodyStreamer {
        static let chunkSize = 32 * 1024
        var handle: NIOFileHandle
        var bytesLeft: Int
        var fileIO: NonBlockingFileIO
        var allocator: ByteBufferAllocator

        init(handle: NIOFileHandle, fileSize: Int, fileIO: NonBlockingFileIO, allocator: ByteBufferAllocator) {
            self.handle = handle
            self.bytesLeft = fileSize
            self.fileIO = fileIO
            self.allocator = allocator
        }

        func read(on eventLoop: EventLoop) -> EventLoopFuture<ResponseBody.StreamResult> {
            let bytesToRead = min(Self.chunkSize, self.bytesLeft)
            if bytesToRead > 0 {
                self.bytesLeft -= bytesToRead
                return self.fileIO.read(fileHandle: self.handle, byteCount: bytesToRead, allocator: self.allocator, eventLoop: eventLoop)
                    .map { .byteBuffer($0) }
            } else {
                try? self.handle.close()
                return eventLoop.makeSucceededFuture(.end)
            }
        }
    }
}