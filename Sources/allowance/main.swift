import AgentAllowanceCore
import Foundation

let arguments = Set(CommandLine.arguments.dropFirst())
let known: Set<String> = ["--json", "--write-cache", "--help", "-h"]

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: allowance --json [--write-cache]

      --json         print the allowance snapshot (schema 1) to stdout
      --write-cache  also write it to ~/Library/Caches/AgentAllowance/usage.json

    Exits 0 even when some providers report errors; those are in the JSON.

    """.utf8))
    exit(arguments.contains("--help") || arguments.contains("-h") ? 0 : 2)
}

guard arguments.contains("--json"), arguments.isSubset(of: known) else { usage() }

let snapshot = AllowanceSnapshot(usages: await UsageService().fetchAll())
do {
    let data = try snapshot.jsonData()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("allowance: could not encode snapshot: \(error)\n".utf8))
    exit(1)
}
if arguments.contains("--write-cache") {
    do {
        try snapshot.writeCache()
    } catch {
        FileHandle.standardError.write(Data("allowance: could not write cache: \(error)\n".utf8))
        exit(1)
    }
}
