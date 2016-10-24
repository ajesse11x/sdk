// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/context/context.dart';
import 'package:analyzer/src/context/source.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/error/todo_codes.dart';
import 'package:analyzer/src/dart/scanner/reader.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisContext, AnalysisEngine, AnalysisOptions, ChangeSet;
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:analyzer/src/summary/api_signature.dart';
import 'package:analyzer/src/summary/flat_buffers.dart' as fb;
import 'package:analyzer/src/summary/format.dart';
import 'package:analyzer/src/summary/idl.dart';
import 'package:analyzer/src/summary/link.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:analyzer/src/summary/summarize_ast.dart';
import 'package:analyzer/src/summary/summarize_elements.dart';
import 'package:analyzer/src/util/fast_uri.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/**
 * This class computes [AnalysisResult]s for Dart files.
 *
 * Let the set of "explicitly analyzed files" denote the set of paths that have
 * been passed to [addFile] but not subsequently passed to [removeFile]. Let
 * the "current analysis results" denote the map from the set of explicitly
 * analyzed files to the most recent [AnalysisResult] delivered to [results]
 * for each file. Let the "current file state" represent a map from file path
 * to the file contents most recently read from that file, or fetched from the
 * content cache (considering all possible possible file paths, regardless of
 * whether they're in the set of explicitly analyzed files). Let the
 * "analysis state" be either "analyzing" or "idle".
 *
 * (These are theoretical constructs; they may not necessarily reflect data
 * structures maintained explicitly by the driver).
 *
 * Then we make the following guarantees:
 *
 *    - Whenever the analysis state is idle, the current analysis results are
 *      consistent with the current file state.
 *
 *    - A call to [addFile] or [changeFile] causes the analysis state to
 *      transition to "analyzing", and schedules the contents of the given
 *      files to be read into the current file state prior to the next time
 *      the analysis state transitions back to "idle".
 *
 *    - If at any time the client stops making calls to [addFile], [changeFile],
 *      and [removeFile], the analysis state will eventually transition back to
 *      "idle" after a finite amount of processing.
 *
 * As a result of these guarantees, a client may ensure that the analysis
 * results are "eventually consistent" with the file system by simply calling
 * [changeFile] any time the contents of a file on the file system have changed.
 *
 *
 * TODO(scheglov) Clean up the list of implicitly analyzed files.
 */
class AnalysisDriver {
  final PerformanceLog _logger;

  /**
   * The resource provider for working with files.
   */
  final ResourceProvider _resourceProvider;

  /**
   * The byte storage to get and put serialized data.
   *
   * It can be shared with other [AnalysisDriver]s.
   */
  final ByteStore _byteStore;

  /**
   * This [ContentCache] is consulted for a file content before reading
   * the content from the file.
   */
  final ContentCache _contentCache;

  /**
   * The [SourceFactory] is used to resolve URIs to paths and restore URIs
   * from file paths.
   */
  final SourceFactory _sourceFactory;

  /**
   * The analysis options to analyze with.
   */
  final AnalysisOptions _analysisOptions;

  /**
   * The combined unlinked and linked package for the SDK, extracted from
   * the given [_sourceFactory].
   */
  PackageBundle _sdkBundle;

  /**
   * The mapping from the files for which analysis was requested using
   * [getResult] to the [Completer]s to report the result.
   */
  final _requestedFiles = <String, List<Completer<AnalysisResult>>>{};

  /**
   * The set of explicitly analyzed files.
   */
  final _explicitFiles = new LinkedHashSet<String>();

  /**
   * The set of files were reported as changed through [changeFile] and for
   * which API signatures should be recomputed and compared before performing
   * any other analysis.
   */
  final _filesToVerifyUnlinkedSignature = new Set<String>();

  /**
   * The set of files that are currently scheduled for analysis.
   */
  final _filesToAnalyze = new LinkedHashSet<String>();

  /**
   * Cache of URI resolution. The outer map key is the absolute URI of the
   * containing file. The inner map key is the URI text of a directive
   * contained in that file. The inner map value is the [Source] object which
   * that URI text resolves to.
   */
  final _uriResolutionCache = <Uri, Map<String, Source>>{};

  /**
   * The current file state.
   *
   * It maps file paths to the MD5 hash of the file content.
   */
  final _fileContentHashMap = <String, String>{};

  /**
   * Mapping from library URIs to the dependency signature of the library.
   */
  final _dependencySignatureMap = <Uri, String>{};

  /**
   * TODO(scheglov) document and improve
   */
  final _hasWorkStreamController = new StreamController<String>();

  AnalysisDriver(this._logger, this._resourceProvider, this._byteStore,
      this._contentCache, this._sourceFactory, this._analysisOptions) {
    _sdkBundle = _sourceFactory.dartSdk.getLinkedBundle();
  }

  /**
   * Set the list of files that the driver should try to analyze sooner.
   *
   * Every path in the list must be absolute and normalized.
   *
   * The driver will produce the results through the [results] stream. The
   * exact order in which results are produced is not defined, neither
   * between priority files, nor between priority and non-priority files.
   */
  void set priorityFiles(List<String> priorityPaths) {
    // TODO(scheglov) implement
  }

  /**
   * Return the [Stream] that produces [AnalysisResult]s for added files.
   *
   * Analysis starts when the client starts listening to the stream, and stops
   * when the client cancels the subscription.
   *
   * When the client starts listening, the analysis state transitions to
   * "analyzing" and an analysis result is produced for every added file prior
   * to the next time the analysis state transitions to "idle".
   *
   * Invocation of [addFile] or [changeFile] might result in producing more
   * analysis results that reflect the new current file state.
   *
   * More than one result might be produced for the same file, even if the
   * client does not change the state of the files.
   *
   * Results might be produced even for files that have never been added
   * using [addFile], for example when [getResult] was called for a file.
   */
  Stream<AnalysisResult> get results async* {
    try {
      while (true) {
        // TODO(scheglov) implement state transitioning
        await for (String why in _hasWorkStreamController.stream) {
          _verifyUnlinkedSignatureOfChangedFiles();

          // Analyze the first file in the general queue.
          if (_filesToAnalyze.isNotEmpty) {
            _logger.run('Analyze ${_filesToAnalyze.length} files', () {
              while (_filesToAnalyze.isNotEmpty) {
                String path = _filesToAnalyze.first;
                _filesToAnalyze.remove(path);
                _File file = _fileForPath(path);
                _computeAndPrintErrors(file);
                // TODO(scheglov) yield the result
              }
            });
          }
        }
        // TODO(scheglov) implement
      }
    } finally {
      print('The stream was cancelled.');
    }
  }

  /**
   * Add the file with the given [path] to the set of files to analyze.
   *
   * The [path] must be absolute and normalized.
   *
   * The results of analysis are eventually produced by the [results] stream.
   */
  void addFile(String path) {
    _explicitFiles.add(path);
    _filesToAnalyze.add(path);
    _hasWorkStreamController.add('do it!');
  }

  /**
   * The file with the given [path] might have changed - updated, added or
   * removed. Or not, we don't know. Or it might have, but then changed back.
   *
   * The [path] must be absolute and normalized.
   *
   * The [path] can be any file - explicitly or implicitly analyzed, or neither.
   *
   * Causes the analysis state to transition to "analyzing" (if it is not in
   * that state already). Schedules the file contents for [path] to be read
   * into the current file state prior to the next time the analysis state
   * transitions to "idle".
   *
   * Invocation of this method will not prevent a [Future] returned from
   * [getResult] from completing with a result, but the result is not
   * guaranteed to be consistent with the new current file state after this
   * [changeFile] invocation.
   */
  void changeFile(String path) {
    _filesToVerifyUnlinkedSignature.add(path);
    _filesToAnalyze.add(path);
    _hasWorkStreamController.add('do it!');
  }

  /**
   * Return the [Future] that completes with a [AnalysisResult] for the file
   * with the given [path].
   *
   * The [path] must be absolute and normalized.
   *
   * The [path] can be any file - explicitly or implicitly analyzed, or neither.
   *
   * Causes the analysis state to transition to "analyzing" (if it is not in
   * that state already), the driver will read the file and produce the analysis
   * result for it, which is consistent with the current file state (including
   * the new state of the file), prior to the next time the analysis state
   * transitions to "idle".
   */
  Future<AnalysisResult> getResult(String path) {
    var completer = new Completer<AnalysisResult>();
    _requestedFiles
        .putIfAbsent(path, () => <Completer<AnalysisResult>>[])
        .add(completer);
    _hasWorkStreamController.add(path);
    return completer.future;
  }

  /**
   * Remove the file with the given [path] from the list of files to analyze.
   *
   * The [path] must be absolute and normalized.
   *
   * The results of analysis of the file might still be produced by the
   * [results] stream. The driver will try to stop producing these results,
   * but does not guarantee this.
   */
  void removeFile(String path) {
    _explicitFiles.remove(path);
    _filesToAnalyze.remove(path);
  }

  /**
   * TODO(scheglov) see [_addToStoreUnlinked]
   */
  void _addToStoreLinked(
      SummaryDataStore store, String uri, LinkedLibrary linked) {
    store.linkedMap[uri] = linked;
  }

  /**
   * TODO(scheglov) The existing [SummaryDataStore.addBundle] uses
   * [PackageBundle.unlinkedUnitUris] to add [PackageBundle.unlinkedUnits].
   * But we store unlinked bundles with the hash of the file content. This
   * means that when two files are the same, but have different URIs, we
   * add [UnlinkedUnit] with wrong URI.
   *
   * We need to clean this up.
   */
  void _addToStoreUnlinked(
      SummaryDataStore store, String uri, UnlinkedUnit unlinked) {
    store.unlinkedMap[uri] = unlinked;
  }

  /**
   * TODO(scheglov) replace with actual [AnalysisResult] computing.
   */
  List<String> _computeAndPrintErrors(_File file) {
    // TODO(scheglov) Computing resolved unit fails for these units.
    // pkg/analyzer/lib/plugin/embedded_resolver_provider.dart
    // pkg/analyzer/lib/plugin/embedded_resolver_provider.dart
    if (file.path.endsWith(
            'pkg/analyzer/lib/plugin/embedded_resolver_provider.dart') ||
        file.path.endsWith('pkg/analyzer/lib/source/embedder.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/ast.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/element.dart') ||
        file.path
            .endsWith('pkg/analyzer/lib/src/generated/element_handle.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/error.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/scanner.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/sdk_io.dart') ||
        file.path.endsWith('pkg/analyzer/lib/src/generated/visitors.dart') ||
        file.path.endsWith('pkg/analyzer/test/generated/constant_test.dart') ||
        file.path.endsWith('pkg/analyzer/test/source/embedder_test.dart')) {
      return [];
    }

    List<String> errorStrings = _logger.run('Compute errors $file', () {
      _LibraryContext libraryContext = _createLibraryContext(file);

      String errorsKey;
      {
        ApiSignature signature = new ApiSignature();
        signature.addString(libraryContext.node.dependencySignature);
        signature.addString(file.contentHash);
        errorsKey = '${signature.toHex()}.errors';
      }

      {
        List<int> bytes = _byteStore.get(errorsKey);
        if (bytes != null) {
          fb.BufferContext bp = new fb.BufferContext.fromBytes(bytes);
          int table = bp.derefObject(0);
          return const fb.ListReader<String>(const fb.StringReader())
              .vTableGet(bp, table, 0);
        }
      }

      AnalysisContext analysisContext = _createAnalysisContext(libraryContext);
      analysisContext.setContents(file.source, file.content);
      try {
        // Compute resolved unit.
//        _logger.runTimed('Computed resolved unit', () {
//          analysisContext.resolveCompilationUnit2(
//              libraryContext.file.source, libraryContext.file.source);
//        });
        // Compute errors.
        List<AnalysisError> errors = _logger.run('Compute errors', () {
          return analysisContext.computeErrors(file.source);
        });
        List<String> errorStrings = errors
            .where((error) => error.errorCode is! TodoCode)
            .map((error) => error.toString())
            .toList();
        {
          fb.Builder fbBuilder = new fb.Builder();
          var exportedOffset = fbBuilder.writeList(errorStrings
              .map((errorStr) => fbBuilder.writeString(errorStr))
              .toList());
          fbBuilder.startTable();
          fbBuilder.addOffset(0, exportedOffset);
          var offset = fbBuilder.endTable();
          List<int> bytes = fbBuilder.finish(offset, 'CErr');
          _byteStore.put(errorsKey, bytes);
        }

        return errorStrings;
      } finally {
        analysisContext.dispose();
      }
    });

    if (errorStrings.isNotEmpty) {
      errorStrings.forEach((errorString) => print('\t$errorString'));
    } else {
      print('\tNO ERRORS');
    }
    return errorStrings;
  }

  AnalysisContext _createAnalysisContext(_LibraryContext libraryContext) {
    AnalysisContextImpl analysisContext =
        AnalysisEngine.instance.createAnalysisContext();

    analysisContext.sourceFactory =
        new SourceFactory((_sourceFactory as SourceFactoryImpl).resolvers);
    analysisContext.resultProvider =
        new InputPackagesResultProvider(analysisContext, libraryContext.store);
    analysisContext
        .applyChanges(new ChangeSet()..addedSource(libraryContext.file.source));
    return analysisContext;
  }

  /**
   * Return the context in which the library represented by the given
   * [libraryFile] should be analyzed it.
   *
   * TODO(scheglov) We often don't need [SummaryDataStore], only dependency
   * signature.
   */
  _LibraryContext _createLibraryContext(_File libraryFile) {
    return _logger.run('Create library context', () {
      Map<String, _LibraryNode> nodes = <String, _LibraryNode>{};
      SummaryDataStore store = new SummaryDataStore(const <String>[]);
      store.addBundle(null, _sdkBundle);

      _LibraryNode createLibraryNodes(_File libraryFile) {
        Uri libraryUri = libraryFile.uri;

        // URIs with the 'dart:' scheme are served from the SDK bundle.
        if (libraryUri.scheme == 'dart') {
          return null;
        }

        String libraryUriStr = libraryUri.toString();
        _LibraryNode node = nodes[libraryUriStr];
        if (node == null) {
          node = new _LibraryNode(this, nodes, libraryUri);
          nodes[libraryUriStr] = node;

          // Append the defining unit.
          _ReferencedUris referenced;
          {
            PackageBundle bundle = _getUnlinked(libraryFile);
            UnlinkedUnit unlinked = bundle.unlinkedUnits.single;
            referenced = new _ReferencedUris(unlinked);
            node.unlinkedBundles.add(bundle);
            _addToStoreUnlinked(store, libraryUriStr, unlinked);
          }

          // Append parts.
          for (String uri in referenced.parted) {
            _File file = libraryFile.resolveUri(uri);
            PackageBundle bundle = _getUnlinked(file);
            UnlinkedUnit unlinked = bundle.unlinkedUnits.single;
            node.unlinkedBundles.add(bundle);
            _addToStoreUnlinked(store, file.uri.toString(), unlinked);
          }

          // Create nodes for referenced libraries.
          for (String uri in referenced.imported) {
            _File file = libraryFile.resolveUri(uri);
            createLibraryNodes(file);
          }
          for (String uri in referenced.exported) {
            _File file = libraryFile.resolveUri(uri);
            createLibraryNodes(file);
          }
        }

        // Done with this node.
        return node;
      }

      _LibraryNode libraryNode = _logger.run('Compute library nodes', () {
        return createLibraryNodes(libraryFile);
      });

      Set<String> libraryUrisToLink = new Set<String>();
      _logger.run('Load linked bundles', () {
        for (_LibraryNode node in nodes.values) {
          String key = '${node.dependencySignature}.linked';
          List<int> bytes = _byteStore.get(key);
          if (bytes != null) {
            PackageBundle linked = new PackageBundle.fromBuffer(bytes);
            _addToStoreLinked(
                store, node.uri.toString(), linked.linkedLibraries.single);
          } else {
            libraryUrisToLink.add(node.uri.toString());
          }
        }
        int numOfLoaded = nodes.length - libraryUrisToLink.length;
        _logger.writeln('Loaded $numOfLoaded linked bundles.');
      });

      Map<String, LinkedLibraryBuilder> linkedLibraries = {};
      _logger.run('Link bundles', () {
        linkedLibraries = link(libraryUrisToLink, (String uri) {
          LinkedLibrary linkedLibrary = store.linkedMap[uri];
          if (linkedLibrary == null) {
            throw new StateError('No linked library for: $uri');
          }
          return linkedLibrary;
        }, (String uri) {
          UnlinkedUnit unlinkedUnit = store.unlinkedMap[uri];
          if (unlinkedUnit == null) {
            throw new StateError('No unlinked unit for: $uri');
          }
          return unlinkedUnit;
        }, (_) => null, _analysisOptions.strongMode);
        _logger.writeln('Linked ${linkedLibraries.length} bundles.');
      });

      linkedLibraries.forEach((uri, linkedBuilder) {
        _LibraryNode node = nodes[uri];
        String key = '${node.dependencySignature}.linked';
        List<int> bytes;
        {
          PackageBundleAssembler assembler = new PackageBundleAssembler();
          assembler.addLinkedLibrary(uri, linkedBuilder);
          bytes = assembler.assemble().toBuffer();
        }
        PackageBundle linked = new PackageBundle.fromBuffer(bytes);
        _addToStoreLinked(store, uri, linked.linkedLibraries.single);
        _byteStore.put(key, bytes);
      });

      return new _LibraryContext(libraryFile, libraryNode, store);
    });
  }

  /**
   * Return the [_File] for the given [path] in [_sourceFactory].
   */
  _File _fileForPath(String path) {
    Source fileSource = _resourceProvider.getFile(path).createSource();
    Uri uri = _sourceFactory.restoreUri(fileSource);
    Source source = _resourceProvider.getFile(path).createSource(uri);
    return new _File(this, source);
  }

  /**
   * Return the unlinked bundle of [file] for the current file state, or `null`.
   */
  PackageBundle _getCurrentUnlinked(_File file) {
    String key = '${file.currentContentHash}.unlinked';
    List<int> bytes = _byteStore.get(key);
    return bytes != null ? new PackageBundle.fromBuffer(bytes) : null;
  }

  /**
   * Return the unlinked bundle of [file] for the current file state.
   *
   * Return [_getCurrentUnlinked] or read the [file] content is read, compute
   * the content hash and update the current file state accordingly. Parse the
   * content into the [CompilationUnit] and serialize into a new unlinked
   * bundle. The bundle is then put into the [_byteStore] and returned.
   */
  PackageBundle _getUnlinked(_File file) {
    // By accessing 'contentHash' we ensure that the current file state
    // has some version of the file content hash, so we will be able to
    // use it to attempt to get the current unlinked bundle.
    String key = '${file.contentHash}.unlinked';
    return _getCurrentUnlinked(file) ??
        _logger.run('Create unlinked for $file', () {
          UnlinkedUnitBuilder unlinkedUnit = serializeAstUnlinked(file.unit);
          PackageBundleAssembler assembler = new PackageBundleAssembler();
          assembler.addUnlinkedUnitWithHash(
              file.uri.toString(), unlinkedUnit, key);
          List<int> bytes = assembler.assemble().toBuffer();
          _byteStore.put(key, bytes);
          return new PackageBundle.fromBuffer(bytes);
        });
  }

  /**
   * Verify the API signatures for the changed files, and decide which linked
   * libraries should be invalidated, and files reanalyzed.
   *
   * TODO(scheglov) I see that adding a local var changes (full) API signature.
   */
  void _verifyUnlinkedSignatureOfChangedFiles() {
    if (_filesToVerifyUnlinkedSignature.isEmpty) {
      return;
    }
    int numOfFiles = _filesToVerifyUnlinkedSignature.length;
    _logger.run('Verify API signatures of $numOfFiles files', () {
      for (String path in _filesToVerifyUnlinkedSignature) {
        _File file = _fileForPath(path);
        // Get the existing old API signature, maybe null.
        String oldSignature = _getCurrentUnlinked(file)?.apiSignature;
        // Clear the content hash cache, so force the file reading.
        _fileContentHashMap.remove(path);
        // Compute the new API signature.
        String newSignature = _getUnlinked(file).apiSignature;
        // If the signatures are not the same, then potentially every linked
        // library is inconsistent and should be recomputed, and every explicit
        // file has inconsistent analysis results which also should be recomputed.
        if (oldSignature != newSignature) {
          _logger.writeln('API signature mismatch found for $file.');
          _dependencySignatureMap.clear();
          _filesToAnalyze.addAll(_explicitFiles);
          // Stop the verification, and restart analysis.
          break;
        }
      }
      _filesToVerifyUnlinkedSignature.clear();
    });
  }
}

/**
 * The result of analyzing of a single file.
 *
 * These results are self-consistent, i.e. [content], [contentHash], the
 * resolved [unit] correspond to each other. All referenced elements, even
 * external ones, are also self-consistent. But none of the results is
 * guaranteed to be consistent with the state of the files.
 *
 * Every result is independent, and is not guaranteed to be consistent with
 * any previously returned result, even inside of the same library.
 */
class AnalysisResult {
  /**
   * The path of the analysed file, absolute and normalized.
   */
  final String path;

  /**
   * The URI of the file that corresponded to the [path] in the used
   * [SourceFactory] at some point. Is it not guaranteed to be still consistent
   * to the [path], and provided as FYI.
   */
  final Uri uri;

  /**
   * The content of the file that was scanned, parsed and resolved.
   */
  final String content;

  /**
   * The MD5 hash of the [content].
   */
  final String contentHash;

  /**
   * The fully resolved compilation unit for the [content].
   */
  final CompilationUnit unit;

  /**
   * The full list of computed analysis errors, both syntactic and semantic.
   */
  final List<AnalysisError> errors;

  AnalysisResult(this.path, this.uri, this.content, this.contentHash, this.unit,
      this.errors);
}

/**
 * This class is used to gather and print performance information.
 */
class PerformanceLog {
  final StringSink sink;
  int _level = 0;

  PerformanceLog(this.sink);

  /**
   * Return the result of the function [f] invocation and log the elapsed time.
   *
   * Each invocation of [run] creates a new enclosed section in the log,
   * which begins with printing [msg], then any log output produced during
   * [f] invocation, and ends with printing [msg] with the elapsed time.
   */
  /*=T*/ run/*<T>*/(String msg, /*=T*/ f()) {
    Stopwatch timer = new Stopwatch()..start();
    try {
      writeln('+++ $msg.');
      _level++;
      return f();
    } finally {
      _level--;
      int ms = timer.elapsedMilliseconds;
      writeln('--- $msg in $ms ms.');
    }
  }

  /**
   * Write a new line into the log
   */
  void writeln(String msg) {
    String indent = '\t' * _level;
    sink.writeln('$indent$msg');
  }
}

/**
 * Information about a file being analyzed, explicitly or implicitly.
 *
 * It keeps a consistent view on its [content], [contentHash] and [unit].
 *
 * Instances of this class may only be used during computing a single analysis
 * result and should not be cached anywhere. We need this limitation to prevent
 * references from caches to the resolved [unit], so to element models, etc.
 * The data structures should be short lived - computed, returned to the client,
 * processed there and quickly thrown away.
 */
class _File {
  /**
   * The driver instance that is used to access [SourceFactory] and caches.
   */
  final AnalysisDriver driver;

  /**
   * The [Source] this [_File] instance represent.
   */
  final Source source;

  String _content;
  String _contentHash;
  CompilationUnit _unit;

  _File(this.driver, this.source);

  /**
   * Return the current content of the file.
   *
   * If the [_content] field if it is still `null`, get the content from the
   * content cache or from the [source]. If the content cannot be accessed
   * because of an exception, it considers to be an empty string.
   *
   * When a new content is read, the new [_contentHash] is computed and the
   * current file state is updated.
   */
  String get content {
    if (_content == null) {
      _readContentAndComputeHash();
    }
    return _content;
  }

  /**
   * Ensure that the content hash is set for this [_File] instance, return it.
   *
   * If the content hash has already been set for this [_File] instance, it is
   * not updated here. But the hash value might be updated on [content] access.
   *
   * If the content hash is known in the current file state, use it.
   *
   * Otherwise, read the [content], compute the hash, put it into the current
   * file state, and update the [contentHash] field.
   *
   * The client should not remember values of this property, because its value
   * might change when [content] is read and the hash is recomputed.
   */
  String get contentHash {
    _contentHash ??= currentContentHash;
    if (_contentHash == null) {
      _readContentAndComputeHash();
    }
    return _contentHash;
  }

  /**
   * Return the hash of the file content in the current file state, or `null`
   * if the current file state does not know the current file content hash.
   */
  String get currentContentHash {
    return driver._fileContentHashMap[path];
  }

  String get path => source.fullName;

  /**
   * Return the unresolved [CompilationUnit] of the file.
   *
   * Performing resolution and computing errors is done in a separate analysis
   * context. In the future we might push the existing unresolved unit into the
   * analysis context, so at some point the unit might become resolved.
   */
  CompilationUnit get unit {
    AnalysisErrorListener errorListener = AnalysisErrorListener.NULL_LISTENER;

    CharSequenceReader reader = new CharSequenceReader(content);
    Scanner scanner = new Scanner(source, reader, errorListener);
    scanner.scanGenericMethodComments = driver._analysisOptions.strongMode;
    Token token = scanner.tokenize();
    LineInfo lineInfo = new LineInfo(scanner.lineStarts);

    Parser parser = new Parser(source, errorListener);
    parser.parseGenericMethodComments = driver._analysisOptions.strongMode;
    _unit = parser.parseCompilationUnit(token);
    _unit.lineInfo = lineInfo;

    return _unit;
  }

  Uri get uri => source.uri;

  /**
   * Return the [_File] for the [uri] referenced in this file.
   */
  _File resolveUri(String uri) {
    // TODO(scheglov) Consider removing this caching after implementing other
    // optimizations, e.g. changeFile() optimization.
    Source uriSource = driver._uriResolutionCache
        .putIfAbsent(this.uri, () => <String, Source>{})
        .putIfAbsent(uri, () => driver._sourceFactory.resolveUri(source, uri));
    return new _File(driver, uriSource);
  }

  @override
  String toString() => uri.toString();

  /**
   * Fill the [_content] and [_contentHash] fields.
   *
   * If the [_content] field is still `null`, get the content from the
   * content cache or from the [source]. If the content cannot be accessed
   * because of an exception, it is considered to be an empty string.
   *
   * When a new content is read, the new [_contentHash] should be computed and
   * the current file state should be updated.
   */
  void _readContentAndComputeHash() {
    try {
      _content = driver._contentCache.getContents(source);
      _content ??= source.contents.data;
    } catch (_) {
      _content = '';
      // TODO(scheglov) We fail to report URI_DOES_NOT_EXIST.
      // On one hand we need to provide an unlinked bundle to prevent
      // analysis context from reading the file (we want it to work
      // hermetically and handle one one file at a time). OTOH,
      // ResynthesizerResultProvider happily reports that any source in the
      // SummaryDataStore has MODIFICATION_TIME `0`. We need to return `-1`
      // for missing files. Maybe add this feature to SummaryDataStore?
    }
    // Compute the content hash.
    List<int> textBytes = UTF8.encode(_content);
    List<int> hashBytes = md5.convert(textBytes).bytes;
    _contentHash = hex.encode(hashBytes);
    // Update the current file state.
    driver._fileContentHashMap[path] = _contentHash;
  }
}

/**
 * TODO(scheglov) document
 */
class _LibraryContext {
  final _File file;
  final _LibraryNode node;
  final SummaryDataStore store;
  _LibraryContext(this.file, this.node, this.store);
}

class _LibraryNode {
  final AnalysisDriver driver;
  final Map<String, _LibraryNode> nodes;
  final Uri uri;
  final List<PackageBundle> unlinkedBundles = <PackageBundle>[];

  Set<_LibraryNode> transitiveDependencies;
  List<_LibraryNode> _dependencies;
  String _dependencySignature;

  _LibraryNode(this.driver, this.nodes, this.uri);

  /**
   * Retrieve the dependencies of this node.
   */
  List<_LibraryNode> get dependencies {
    if (_dependencies == null) {
      Set<_LibraryNode> dependencies = new Set<_LibraryNode>();

      void appendDependency(String uriStr) {
        Uri uri = FastUri.parse(uriStr);
        if (uri.scheme == 'dart') {
          // Dependency on the SDK is implicit and always added.
          // The SDK linked bundle is precomputed before linking packages.
        } else {
          if (!uri.isAbsolute) {
            uri = resolveRelativeUri(this.uri, uri);
            uriStr = uri.toString();
          }
          _LibraryNode node = nodes[uriStr];
          if (node == null) {
            throw new StateError('No node for: $uriStr');
          }
          dependencies.add(node);
        }
      }

      for (PackageBundle unlinkedBundle in unlinkedBundles) {
        for (UnlinkedUnit unit in unlinkedBundle.unlinkedUnits) {
          for (UnlinkedImport import in unit.imports) {
            if (!import.isImplicit) {
              appendDependency(import.uri);
            }
          }
          for (UnlinkedExportPublic export in unit.publicNamespace.exports) {
            appendDependency(export.uri);
          }
        }
      }

      _dependencies = dependencies.toList();
    }
    return _dependencies;
  }

  String get dependencySignature {
    return _dependencySignature ??=
        driver._dependencySignatureMap.putIfAbsent(uri, () {
      computeTransitiveDependencies();

      // Add all unlinked API signatures.
      List<String> signatures = <String>[];
      signatures.add(driver._sdkBundle.apiSignature);
      transitiveDependencies
          .map((node) => node.unlinkedBundles)
          .expand((bundles) => bundles)
          .map((bundle) => bundle.apiSignature)
          .forEach(signatures.add);
      signatures.sort();

      // Combine into a single hash.
      ApiSignature signature = new ApiSignature();
      signature.addString(uri.toString());
      signatures.forEach(signature.addString);
      return signature.toHex();
    });
  }

  @override
  int get hashCode => uri.hashCode;

  bool operator ==(other) {
    return other is _LibraryNode && other.uri == uri;
  }

  void computeTransitiveDependencies() {
    if (transitiveDependencies == null) {
      transitiveDependencies = new Set<_LibraryNode>();

      void appendDependencies(_LibraryNode node) {
        if (transitiveDependencies.add(node)) {
          node.dependencies.forEach(appendDependencies);
        }
      }

      appendDependencies(this);
    }
  }

  @override
  String toString() => uri.toString();
}

/**
 * TODO(scheglov) document
 */
class _ReferencedUris {
  bool isLibrary = true;
  final List<String> imported = <String>[];
  final List<String> exported = <String>[];
  final List<String> parted = <String>[];

  factory _ReferencedUris(UnlinkedUnit unit) {
    _ReferencedUris referenced = new _ReferencedUris._();
    referenced.parted.addAll(unit.publicNamespace.parts);
    for (UnlinkedImport import in unit.imports) {
      if (!import.isImplicit) {
        referenced.imported.add(import.uri);
      }
    }
    for (UnlinkedExportPublic export in unit.publicNamespace.exports) {
      referenced.exported.add(export.uri);
    }
    return referenced;
  }

  _ReferencedUris._();
}
