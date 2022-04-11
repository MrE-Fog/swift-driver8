//===--------------- Toolchain.swift - Swift Toolchain Abstraction --------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import TSCBasic
import SwiftOptions

public enum Tool: Hashable {
  case swiftCompiler
  case staticLinker(LTOKind?)
  case dynamicLinker
  case clang
  case clangxx
  case swiftAutolinkExtract
  case dsymutil
  case lldb
  case dwarfdump
  case swiftHelp
  case swiftAPIDigester

  /// Returns a value indicating whether or not the tool supports passing arguments via response
  /// files.
  public func supportsResponseFiles(in toolchain: Toolchain) -> Bool {
    switch self {
    case .swiftCompiler, .clang, .clangxx, .swiftAutolinkExtract, .swiftAPIDigester:
      return true

    case .dsymutil, .lldb, .dwarfdump, .swiftHelp:
      // NOTE: Consider *very carefully* whether a tool actually belongs here when adding a new
      // entry. Incorrectly marking a tool as not supporting response files when it does may cause
      // large builds to fail that would have otherwise succeeded.
      return false

    case .staticLinker, .dynamicLinker:
      // FIXME: newer ld64 supports response files as well, though really,
      // Darwin should use clang as the linker driver like the other targets
      return !(toolchain is DarwinToolchain)
    }
  }
}

/// Encapsulates the path to a tool and the knowledge of whether or not it supports taking long
/// command lines as response files.
public struct ResolvedTool {
  /// The absolute path to the tool's executable.
  public var path: AbsolutePath

  /// Indicates whether the tool can accept long command lines in a response file.
  public var supportsResponseFiles: Bool

  /// Creates a new resolved tool with the given path and response file nature.
  ///
  /// - Note: In most cases, you should **not** call this initializer directly. Instead, use the
  /// `Toolchain.resolvedTool(_:pathOverride:)` method, which computes these values based on the
  /// requested tool and toolchain.
  @_spi(Testing) public init(path: AbsolutePath, supportsResponseFiles: Bool) {
    self.path = path
    self.supportsResponseFiles = supportsResponseFiles
  }
}

/// Describes a toolchain, which includes information about compilers, linkers
/// and other tools required to build Swift code.
public protocol Toolchain {
  init(env: [String: String], executor: DriverExecutor, fileSystem: FileSystem, compilerExecutableDir: AbsolutePath?, toolDirectory: AbsolutePath?)

  var env: [String: String] { get }

  var fileSystem: FileSystem { get }

  var searchPaths: [AbsolutePath] { get }

  var executor: DriverExecutor { get }

  /// Where we should find compiler executables, e.g. XcodeDefault.xctoolchain/usr/bin
  var compilerExecutableDir: AbsolutePath? { get }

  var toolDirectory: AbsolutePath? { get }

  /// Retrieve the absolute path to a particular tool.
  func getToolPath(_ tool: Tool) throws -> AbsolutePath

  /// Set an absolute path to be used for a particular tool.
  func overrideToolPath(_ tool: Tool, path: AbsolutePath)

  /// Remove the absolute path used for a particular tool, in case it was overridden or cached.
  func clearKnownToolPath(_ tool: Tool)

  /// Returns path of the default SDK, if there is one.
  func defaultSDKPath(_ target: Triple?) throws -> AbsolutePath?

  /// When the compiler invocation should be stored in debug information.
  var shouldStoreInvocationInDebugInfo: Bool { get }

  /// Specific toolchains should override this to provide additional
  /// -debug-prefix-map entries. For example, Darwin has an
  /// RC_DEBUG_PREFIX_MAP environment variable that is also understood
  /// by Clang.
  var globalDebugPathRemapping: String? { get }

  /// Constructs a proper output file name for a linker product.
  func makeLinkerOutputFilename(moduleName: String, type: LinkOutputType) -> String

  /// Perform platform-specific argument validation.
  func validateArgs(_ parsedOptions: inout ParsedOptions,
                    targetTriple: Triple,
                    targetVariantTriple: Triple?,
                    compilerOutputType: FileType?,
                    diagnosticsEngine: DiagnosticsEngine) throws

  /// Adds platform-specific linker flags to the provided command line
  func addPlatformSpecificLinkerArgs(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType,
    inputs: [TypedVirtualPath],
    outputFile: VirtualPath,
    shouldUseInputFileList: Bool,
    lto: LTOKind?,
    sanitizers: Set<Sanitizer>,
    targetInfo: FrontendTargetInfo
  ) throws -> ResolvedTool

  func runtimeLibraryName(
    for sanitizer: Sanitizer,
    targetTriple: Triple,
    isShared: Bool
  ) throws -> String

  func platformSpecificInterpreterEnvironmentVariables(
    env: [String: String],
    parsedOptions: inout ParsedOptions,
    sdkPath: VirtualPath.Handle?,
    targetInfo: FrontendTargetInfo) throws -> [String: String]

  func addPlatformSpecificCommonFrontendOptions(
    commandLine: inout [Job.ArgTemplate],
    inputs: inout [TypedVirtualPath],
    frontendTargetInfo: FrontendTargetInfo,
    driver: Driver
  ) throws

  var dummyForTestingObjectFormat: Triple.ObjectFormat {get}
}

extension Toolchain {
  public var searchPaths: [AbsolutePath] {
      // Conditionalize this on the build time host because cross-compiling from
      // a non-Windows host, we would use a Windows toolchain, but would want to
      // use the platform variable for the path.
#if os(Windows)
      return getEnvSearchPaths(pathString: env["Path"], currentWorkingDirectory: fileSystem.currentWorkingDirectory)
#else
      return getEnvSearchPaths(pathString: env["PATH"], currentWorkingDirectory: fileSystem.currentWorkingDirectory)
#endif
  }

  /// Returns the `executablePath`'s directory.
  public var executableDir: AbsolutePath {
    // If the path is given via the initializer, use that.
    if let givenDir = compilerExecutableDir {
      return givenDir
    }
    // If the path isn't given, we are running the driver as an executable,
    // so assuming the compiler is adjacent to the driver.
    guard let path = Bundle.main.executablePath else {
      fatalError("Could not find executable path.")
    }
    return AbsolutePath(path).parentDirectory
  }

  /// Looks for `SWIFT_DRIVER_TOOLNAME_EXEC` in the `env` property.
  /// - Returns: Environment variable value, if any.
  func envVar(forExecutable toolName: String) -> String? {
    return env[envVarName(for: toolName)]
  }

  /// - Returns: String in the form of: `SWIFT_DRIVER_TOOLNAME_EXEC`
  private func envVarName(for toolName: String) -> String {
    var lookupName = toolName
#if os(Windows)
    lookupName = lookupName.replacingOccurrences(of: ".exe", with: "")
#endif
    lookupName = lookupName.replacingOccurrences(of: "-", with: "_").uppercased()
    return "SWIFT_DRIVER_\(lookupName)_EXEC"
  }

  /// Use this property only for testing purposes, for example,
  /// to enable cross-compiling tests that depends on macOS tooling such as `dsymutil`.
  ///
  /// Returns true if `SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK` is set to `1`.
  private var fallbackToExecutableDefaultPath: Bool {
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] == "1"
  }

  /// Looks for the executable in the `SWIFT_DRIVER_TOOLNAME_EXEC` environment variable, if found nothing,
  /// looks in the `executableDir`, `xcrunFind` or in the `searchPaths`.
  /// - Parameter executable: executable to look for [i.e. `swift`].
  func lookup(executable: String) throws -> AbsolutePath {
    if let overrideString = envVar(forExecutable: executableName(executable)) {
      return try AbsolutePath(validating: overrideString)
    } else if let toolDir = toolDirectory,
              let path = lookupExecutablePath(filename: executableName(executable), searchPaths: [toolDir]) {
      // Looking for tools from the tools directory.
      return path
    } else if let path = lookupExecutablePath(filename: executableName(executable), searchPaths: [executableDir]) {
      return path
    } else if let path = try? xcrunFind(executable: executableName(executable)) {
      return path
    } else if !["swift-frontend", "swift", "swift-frontend.exe", "swift.exe"].contains(executable),
              let parentDirectory = try? getToolPath(.swiftCompiler).parentDirectory,
              parentDirectory != executableDir,
              let path = lookupExecutablePath(filename: executableName(executable), searchPaths: [parentDirectory]) {
      // If the driver library's client and the frontend are in different directories,
      // try looking for tools next to the frontend.
      return path
    } else if let path = lookupExecutablePath(filename: executableName(executable), searchPaths: searchPaths) {
      return path
    } else if executable == executableName("swift-frontend") {
      // Temporary shim: fall back to looking for "swift" before failing.
      return try lookup(executable: executableName("swift"))
    } else if fallbackToExecutableDefaultPath {
      if self is WindowsToolchain {
        return try getToolPath(.swiftCompiler)
                .parentDirectory
                .appending(component: executable)
      } else {
        return AbsolutePath("/usr/bin/" + executable)
      }
    } else {
      throw ToolchainError.unableToFind(tool: executable)
    }
  }

  private func xcrunFind(executable: String) throws -> AbsolutePath {
    let xcrun = "xcrun"
    guard lookupExecutablePath(filename: xcrun, searchPaths: searchPaths) != nil else {
      throw ToolchainError.unableToFind(tool: xcrun)
    }

    let path = try executor.checkNonZeroExit(
      args: xcrun, "--find", executable,
      environment: env
    ).spm_chomp()
    return AbsolutePath(path)
  }

  public func validateArgs(_ parsedOptions: inout ParsedOptions,
                           targetTriple: Triple, targetVariantTriple: Triple?,
                           compilerOutputType: FileType?,
                           diagnosticsEngine: DiagnosticsEngine) {}

  public func addPlatformSpecificCommonFrontendOptions(
    commandLine: inout [Job.ArgTemplate],
    inputs: inout [TypedVirtualPath],
    frontendTargetInfo: FrontendTargetInfo,
    driver: Driver
  ) throws {}

  /// Resolves the path to the given tool and whether or not it supports response files so that it
  /// can be passed to a job.
  ///
  /// - Parameters:
  ///   - tool: The `Tool` to resolve. Whether or not the invocation supports response files is
  ///     determined based on how this value responds to the `supportsResponseFiles(in:)` method.
  ///   - pathOverride: If provided, this path will be used as the path to the tool's executable
  ///     instead of the default path determined by the toolchain.
  /// - Returns: A `ResolvedTool` value that provides the path and response file information about
  ///   the tool when creating a `Job`.
  public func resolvedTool(_ tool: Tool, pathOverride: AbsolutePath? = nil) throws -> ResolvedTool {
    return ResolvedTool(
      path: try pathOverride ?? getToolPath(tool),
      supportsResponseFiles: tool.supportsResponseFiles(in: self)
    )
  }
}

@_spi(Testing) public enum ToolchainError: Swift.Error {
  case unableToFind(tool: String)
}
