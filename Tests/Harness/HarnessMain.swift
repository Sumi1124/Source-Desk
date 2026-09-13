import Foundation
import SourceDeskCore

/// Entry point for the verification harness.
///
///   swift run SourceDeskHarness              # everything
///   swift run SourceDeskHarness --filter zip # one area, by suite or test name
///
/// Exits non-zero when anything fails, so it doubles as the CI gate.
@main
struct HarnessMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // Non-test modes are handled before anything else so they never run the suite.
        if arguments.contains("--debug-scratch") { try? DebugScratch.run(); exit(0) }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Usage: SourceDeskHarness [--filter <substring>] [--quiet]

              --filter, -f <text>   run only suites or tests whose name contains <text>
              --quiet, -q           print failures only
              --debug-scratch       run ad-hoc diagnostics

            Set SOURCEDESK_LIVE_WEB=1 to include tests that use the public internet.
            """)
            exit(0)
        }

        var filter: String?
        var quiet = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--filter", "-f": filter = iterator.next()
            case "--quiet", "-q": quiet = true
            default:
                if !argument.hasPrefix("-") { filter = argument }
            }
        }

        print("SourceDesk verification harness")
        print("Library: \(AppPaths.standard().root.path)")

        let suites: [TestSuite] = [
            StoreSuite.suite,
            TextSuite.suite,
            ExtractionSuite.suite,
            ChunkingSuite.suite,
            EmbeddingSuite.suite,
            RetrievalSuite.suite,
            ProviderSuite.suite,
            SearchSuite.suite,
            StudyToolsSuite.suite,
            ArchiveSuite.suite,
            SettingsSuite.suite,
            EndToEndSuite.suite,
            OllamaCloudSuite.suite,
            ModelMenuSuite.suite,
            ResearchSuite.suite,
            BoilerplateSuite.suite,
            ResearchNoteSuite.suite,
            WholeDocumentSuite.suite,
            LiveLocalModelSuite.suite,
            LiveModelHarnessSuite.suite,
            ScopeOverrideSuite.suite,
            SourceDiscoverySuite.suite,
            DuckDuckGoAPISuite.suite,
            FindSourcesFlowSuite.suite,
            PresentationSuite.suite,
        ]

        let result = await Harness.run(suites: suites, filter: filter, verbose: !quiet)
        exit(Harness.report(result))
    }
}
