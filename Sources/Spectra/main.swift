import Foundation

let arguments = CommandLine.arguments
if arguments.contains("--snapshot") {
    exit(Snapshot.run(arguments))
} else {
    SpectraApp.main()
}
