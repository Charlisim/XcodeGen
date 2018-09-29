import Foundation
import JSONUtilities
import PathKit
import ProjectSpec
import xcproj
import Yams

public class ProjectGenerator {

    let project: Project

    public init(project: Project) {
        self.project = project
    }

    var defaultDebugConfig: Config {
        return project.configs.first { $0.type == .debug }!
    }

    var defaultReleaseConfig: Config {
        return project.configs.first { $0.type == .release }!
    }

    public func generateXcodeProject(validate: Bool = true) throws -> XcodeProj {
        if validate {
            try project.validate()
        }
        let pbxProjGenerator = PBXProjGenerator(project: project)
        let pbxProject = try pbxProjGenerator.generate()
        let workspace = try generateWorkspace()
        let sharedData = try generateSharedData(pbxProject: pbxProject)
        return XcodeProj(workspace: workspace, pbxproj: pbxProject, sharedData: sharedData)
    }

    public func generateFiles() throws {

        /*
         Default info plist attributes taken from:
         /Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/Project Templates/Base/Base_DefinitionsInfoPlist.xctemplate/TemplateInfo.plist
        */
        var defaultInfoPlist: [String: Any] = [:]
        defaultInfoPlist["CFBundleIdentifier"] = "$(PRODUCT_BUNDLE_IDENTIFIER)"
        defaultInfoPlist["CFBundleInfoDictionaryVersion"] = "6.0"
        defaultInfoPlist["CFBundleExecutable"] = "$(EXECUTABLE_NAME)"
        defaultInfoPlist["CFBundleName"] = "$(PRODUCT_NAME)"
        defaultInfoPlist["CFBundleDevelopmentRegion"] = "$(DEVELOPMENT_LANGUAGE)"
        defaultInfoPlist["CFBundleShortVersionString"] = "1.0"
        defaultInfoPlist["CFBundleVersion"] = "1"

        for target in project.targets {
            if let plist = target.info {
                var targetInfoPlist = defaultInfoPlist
                switch target.type {
                case .uiTestBundle,
                     .unitTestBundle:
                    targetInfoPlist["CFBundlePackageType"] = "BNDL"
                case .application,
                     .watch2App:
                    targetInfoPlist["CFBundlePackageType"] = "APPL"
                case .framework:
                    targetInfoPlist["CFBundlePackageType"] = "FMWK"
                case .bundle:
                    targetInfoPlist["CFBundlePackageType"] = "BNDL"
                case .xpcService:
                    targetInfoPlist["CFBundlePackageType"] = "XPC"
                default: break
                }
                let path = project.basePath + plist.path
                let attributes = targetInfoPlist.merged(plist.attributes)
                let data = try PropertyListSerialization.data(fromPropertyList: attributes, format: .xml, options: 0)
                try? path.delete()
                try path.parent().mkpath()
                try path.write(data)
            }

            if let plist = target.entitlements {
                let path = project.basePath + plist.path
                let data = try PropertyListSerialization.data(fromPropertyList: plist.attributes, format: .xml, options: 0)
                try? path.delete()
                try path.parent().mkpath()
                try path.write(data)
            }
        }
    }

    func generateWorkspace() throws -> XCWorkspace {
        let dataElement: XCWorkspaceDataElement = .file(XCWorkspaceDataFileRef(location: .self("")))
        let workspaceData = XCWorkspaceData(children: [dataElement])
        return XCWorkspace(data: workspaceData)
    }

    func generateScheme(_ scheme: Scheme, pbxProject: PBXProj) throws -> XCScheme {

        func getBuildEntry(_ buildTarget: Scheme.BuildTarget) -> XCScheme.BuildAction.Entry {

            guard let targetReference = pbxProject.objects.targets(named: buildTarget.target).first else {
                fatalError("Unable to find target named \"\(buildTarget.target)\" in \"PBXProj.objects.targets\"")
            }

            guard let buildableName =
                project.getTarget(buildTarget.target)?.filename ??
                project.getAggregateTarget(buildTarget.target)?.name else {
                fatalError("Unable to determinate \"buildableName\" for build target: \(buildTarget.target)")
            }
            let buildableReference = XCScheme.BuildableReference(
                referencedContainer: "container:\(project.name).xcodeproj",
                blueprintIdentifier: targetReference.reference,
                buildableName: buildableName,
                blueprintName: buildTarget.target
            )
            return XCScheme.BuildAction.Entry(buildableReference: buildableReference, buildFor: buildTarget.buildTypes)
        }

        let testTargetNames = scheme.test?.targets ?? []
        let testBuildTargets = testTargetNames.map {
            Scheme.BuildTarget(target: $0, buildTypes: BuildType.testOnly)
        }

        let testBuildTargetEntries = testBuildTargets.map(getBuildEntry)

        let buildActionEntries: [XCScheme.BuildAction.Entry] = scheme.build.targets.map(getBuildEntry)

        func getExecutionAction(_ action: Scheme.ExecutionAction) -> XCScheme.ExecutionAction {
            // ExecutionActions can require the use of build settings. Xcode allows the settings to come from a build or test target.
            let environmentBuildable = action.settingsTarget.flatMap { settingsTarget in
                return (buildActionEntries + testBuildTargetEntries)
                    .first { settingsTarget == $0.buildableReference.blueprintName }?
                    .buildableReference
            }
            return XCScheme.ExecutionAction(scriptText: action.script, title: action.name, environmentBuildable: environmentBuildable)
        }

        let target = project.getTarget(scheme.build.targets.first!.target)
        let shouldExecuteOnLaunch = target?.type.isExecutable == true

        let buildableReference = buildActionEntries.first!.buildableReference
        let productRunable = XCScheme.BuildableProductRunnable(buildableReference: buildableReference)

        let buildAction = XCScheme.BuildAction(
            buildActionEntries: buildActionEntries,
            preActions: scheme.build.preActions.map(getExecutionAction),
            postActions: scheme.build.postActions.map(getExecutionAction),
            parallelizeBuild: scheme.build.parallelizeBuild,
            buildImplicitDependencies: scheme.build.buildImplicitDependencies
        )

        let testables = testBuildTargetEntries.map {
            XCScheme.TestableReference(skipped: false, buildableReference: $0.buildableReference)
        }

        let testCommandLineArgs = scheme.test.map { XCScheme.CommandLineArguments($0.commandLineArguments) }
        let launchCommandLineArgs = scheme.run.map { XCScheme.CommandLineArguments($0.commandLineArguments) }
        let profileCommandLineArgs = scheme.profile.map { XCScheme.CommandLineArguments($0.commandLineArguments) }

        let testVariables = scheme.test.flatMap { $0.environmentVariables.isEmpty ? nil : $0.environmentVariables }
        let launchVariables = scheme.run.flatMap { $0.environmentVariables.isEmpty ? nil : $0.environmentVariables }
        let profileVariables = scheme.profile.flatMap { $0.environmentVariables.isEmpty ? nil : $0.environmentVariables }

        let testAction = XCScheme.TestAction(
            buildConfiguration: scheme.test?.config ?? defaultDebugConfig.name,
            macroExpansion: buildableReference,
            testables: testables,
            preActions: scheme.test?.preActions.map(getExecutionAction) ?? [],
            postActions: scheme.test?.postActions.map(getExecutionAction) ?? [],
            shouldUseLaunchSchemeArgsEnv: scheme.test?.shouldUseLaunchSchemeArgsEnv ?? true,
            codeCoverageEnabled: scheme.test?.gatherCoverageData ?? false,
            commandlineArguments: testCommandLineArgs,
            environmentVariables: testVariables
        )

        let launchAction = XCScheme.LaunchAction(
            buildableProductRunnable: shouldExecuteOnLaunch ? productRunable : nil,
            buildConfiguration: scheme.run?.config ?? defaultDebugConfig.name,
            preActions: scheme.run?.preActions.map(getExecutionAction) ?? [],
            postActions: scheme.run?.postActions.map(getExecutionAction) ?? [],
            macroExpansion: shouldExecuteOnLaunch ? nil : buildableReference,
            commandlineArguments: launchCommandLineArgs,
            environmentVariables: launchVariables
        )

        let profileAction = XCScheme.ProfileAction(
            buildableProductRunnable: productRunable,
            buildConfiguration: scheme.profile?.config ?? defaultReleaseConfig.name,
            preActions: scheme.profile?.preActions.map(getExecutionAction) ?? [],
            postActions: scheme.profile?.postActions.map(getExecutionAction) ?? [],
            shouldUseLaunchSchemeArgsEnv: scheme.profile?.shouldUseLaunchSchemeArgsEnv ?? true,
            commandlineArguments: profileCommandLineArgs,
            environmentVariables: profileVariables
        )

        let analyzeAction = XCScheme.AnalyzeAction(buildConfiguration: scheme.analyze?.config ?? defaultDebugConfig.name)

        let archiveAction = XCScheme.ArchiveAction(
            buildConfiguration: scheme.archive?.config ?? defaultReleaseConfig.name,
            revealArchiveInOrganizer: scheme.archive?.revealArchiveInOrganizer ?? true,
            customArchiveName: scheme.archive?.customArchiveName,
            preActions: scheme.archive?.preActions.map(getExecutionAction) ?? [],
            postActions: scheme.archive?.postActions.map(getExecutionAction) ?? []
        )

        return XCScheme(
            name: scheme.name,
            lastUpgradeVersion: project.xcodeVersion,
            version: project.schemeVersion,
            buildAction: buildAction,
            testAction: testAction,
            launchAction: launchAction,
            profileAction: profileAction,
            analyzeAction: analyzeAction,
            archiveAction: archiveAction
        )
    }

    func generateSharedData(pbxProject: PBXProj) throws -> XCSharedData {
        var xcschemes: [XCScheme] = []

        for scheme in project.schemes {
            let xcscheme = try generateScheme(scheme, pbxProject: pbxProject)
            xcschemes.append(xcscheme)
        }

        for target in project.targets {
            if let targetScheme = target.scheme {

                if targetScheme.configVariants.isEmpty {
                    let schemeName = target.name

                    let debugConfig = project.configs.first { $0.type == .debug }!
                    let releaseConfig = project.configs.first { $0.type == .release }!

                    let scheme = Scheme(
                        name: schemeName,
                        target: target,
                        targetScheme: targetScheme,
                        debugConfig: debugConfig.name,
                        releaseConfig: releaseConfig.name
                    )
                    let xcscheme = try generateScheme(scheme, pbxProject: pbxProject)
                    xcschemes.append(xcscheme)
                } else {
                    for configVariant in targetScheme.configVariants {

                        let schemeName = "\(target.name) \(configVariant)"

                        let debugConfig = project.configs
                            .first { $0.type == .debug && $0.name.contains(configVariant) }!
                        let releaseConfig = project.configs
                            .first { $0.type == .release && $0.name.contains(configVariant) }!

                        let scheme = Scheme(
                            name: schemeName,
                            target: target,
                            targetScheme: targetScheme,
                            debugConfig: debugConfig.name,
                            releaseConfig: releaseConfig.name
                        )
                        let xcscheme = try generateScheme(scheme, pbxProject: pbxProject)
                        xcschemes.append(xcscheme)
                    }
                }
            }
        }

        return XCSharedData(schemes: xcschemes)
    }
}

extension Scheme {
    public init(name: String, target: Target, targetScheme: TargetScheme, debugConfig: String, releaseConfig: String) {
        self.init(
            name: name,
            build: .init(targets: [Scheme.BuildTarget(target: target.name)]),
            run: .init(
                config: debugConfig,
                commandLineArguments: targetScheme.commandLineArguments,
                preActions: targetScheme.preActions,
                postActions: targetScheme.postActions,
                environmentVariables: targetScheme.environmentVariables
            ),
            test: .init(
                config: debugConfig,
                gatherCoverageData: targetScheme.gatherCoverageData,
                commandLineArguments: targetScheme.commandLineArguments,
                targets: targetScheme.testTargets,
                preActions: targetScheme.preActions,
                postActions: targetScheme.postActions,
                environmentVariables: targetScheme.environmentVariables
            ),
            profile: .init(
                config: releaseConfig,
                commandLineArguments: targetScheme.commandLineArguments,
                preActions: targetScheme.preActions,
                postActions: targetScheme.postActions,
                environmentVariables: targetScheme.environmentVariables
            ),
            analyze: .init(
                config: debugConfig
            ),
            archive: .init(
                config: releaseConfig,
                preActions: targetScheme.preActions,
                postActions: targetScheme.postActions
            )
        )
    }
}
