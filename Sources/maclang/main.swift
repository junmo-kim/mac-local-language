import Foundation
import LangCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--version" || arguments.first == "version" {
    print("maclang \(Version.current)")
    exit(0)
}
FileHandle.standardError.write(Data("usage: maclang --version\n".utf8))
exit(64)
