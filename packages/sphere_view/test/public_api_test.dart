@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Phase 13 §2 — the public API audit, as a check rather than as a reading.
///
/// The rule it enforces is that **nothing under `src/` may appear in a public
/// signature unless the barrel exports it**. A leak is invisible until it is
/// expensive: the package compiles, the example app compiles, and the first
/// person to hit it is a consumer trying to write down the type of something
/// this package handed them — a variable they cannot declare, a subclass they
/// cannot write, a mock they cannot make. By then it is in a release and taking
/// it back is a breaking change.
///
/// It is done on the resolved element model rather than by reading imports,
/// because the leak is a property of the *types in the signatures*, and a type
/// can arrive in a signature without its file ever being named — through a
/// return type's type argument, a supertype, an inherited member, a typedef.
/// Every one of those is walked here.
void main() {
  late LibraryElement library;
  late Set<Element> exported;
  late Map<String, Element> exportedByName;

  setUpAll(() async {
    final root = Directory.current.path;
    final barrel = p.normalize(p.join(root, 'lib', 'sphere_view.dart'));
    expect(
      File(barrel).existsSync(),
      isTrue,
      reason: 'run this from the package root; looked for $barrel',
    );

    final collection = AnalysisContextCollection(
      includedPaths: [barrel],
      // Explicit, because under `flutter test` the running executable is
      // `flutter_tester`, several directories away from the Dart SDK inside
      // the Flutter cache. The analyzer's own discovery walks up from the
      // executable, lands in the engine artifacts directory and fails with a
      // missing-file error that says nothing about what is wrong.
      sdkPath: _dartSdkPath(),
    );
    final resolved =
        await collection.contextFor(barrel).currentSession.getResolvedLibrary(barrel);
    expect(
      resolved,
      isA<ResolvedLibraryResult>(),
      reason: 'the barrel did not resolve: $resolved',
    );
    library = (resolved as ResolvedLibraryResult).element;
    exportedByName = library.exportNamespace.definedNames2;
    exported = exportedByName.values.toSet();
  });

  test('the barrel exports something, so a broken resolve cannot pass', () {
    // Everything below is of the form "nothing was found to be wrong". If the
    // resolve silently produced an empty library, every one of them would pass
    // for the worst possible reason.
    expect(exported.length, greaterThan(50));
  });

  test('no src/ type reaches a public signature without being exported', () {
    final leaks = <String>[];

    void check(String owner, DartType? type) {
      for (final element in _elementsIn(type)) {
        if (!_isInSrc(element)) continue;
        if (exported.contains(element)) continue;
        leaks.add('$owner → ${element.name ?? '<unnamed>'} '
            '(${_shortUri(element)})');
      }
    }

    for (final entry in exportedByName.entries) {
      final owner = entry.key;
      final element = entry.value;

      switch (element) {
        case InterfaceElement():
          // A supertype or interface that is not exported is the subtlest leak
          // of the lot: every inherited member's signature is then written in a
          // vocabulary the consumer has no words for.
          check('$owner (supertype)', element.supertype);
          for (final type in element.interfaces) {
            check('$owner (interface)', type);
          }
          for (final type in element.mixins) {
            check('$owner (mixin)', type);
          }
          for (final parameter in element.typeParameters) {
            check('$owner (type parameter bound)', parameter.bound);
          }
          for (final constructor in element.constructors) {
            if (_skip(constructor)) continue;
            _checkExecutable(
              '$owner.${constructor.name ?? 'new'}',
              constructor,
              check,
            );
          }
          for (final method in element.methods) {
            if (_skip(method)) continue;
            _checkExecutable('$owner.${method.name}', method, check);
          }
          for (final getter in element.getters) {
            if (_skip(getter)) continue;
            check('$owner.${getter.name}', getter.returnType);
          }
          for (final setter in element.setters) {
            if (_skip(setter)) continue;
            _checkExecutable('$owner.${setter.name}', setter, check);
          }

        case TypeAliasElement():
          check('$owner (typedef)', element.aliasedType);

        case TopLevelFunctionElement():
          _checkExecutable(owner, element, check);

        case TopLevelVariableElement():
          check(owner, element.type);

        case GetterElement():
          check(owner, element.returnType);

        case SetterElement():
          _checkExecutable(owner, element, check);

        default:
          break;
      }
    }

    expect(
      leaks,
      isEmpty,
      reason:
          'These src/ types appear in a public signature but are not exported '
          'from lib/sphere_view.dart. Either export them (with a comment '
          'saying why they are part of the surface) or take them out of the '
          'signature:\n  ${leaks.join('\n  ')}',
    );
  });

  test('every exported declaration carries a doc comment', () {
    // Members are the `public_member_api_docs` lint's job, and it is on in
    // `analysis_options.yaml`, so `flutter analyze` catches those while you
    // type. This is the backstop one level up: an element can reach the export
    // namespace from a file, and in a shape, that the person adding the export
    // line never opened.
    final undocumented = [
      for (final entry in exportedByName.entries)
        if ((entry.value.documentationComment ?? '').trim().isEmpty) entry.key,
    ];
    expect(undocumented, isEmpty, reason: undocumented.join('\n'));
  });

  test('the barrel exports by name, never wholesale', () {
    // A bare `export 'src/foo.dart';` is how the surface grows without anybody
    // deciding that it should: the next public class added to that file joins
    // the API, silently, in whatever shape it happened to have. Every export
    // here carries a `show`, so adding to the surface is an edit somebody has
    // to make on purpose.
    final source = File(
      p.join(Directory.current.path, 'lib', 'sphere_view.dart'),
    ).readAsStringSync();
    final withoutShow = <String>[];
    for (final match
        in RegExp(r"^export\s+'([^']+)'([^;]*);", multiLine: true)
            .allMatches(source)) {
      if (!match.group(2)!.contains('show')) withoutShow.add(match.group(1)!);
    }
    expect(withoutShow, isEmpty, reason: withoutShow.join(', '));
  });
}

/// The Dart SDK the analyzer should resolve `dart:` against.
///
/// Identified by a file that only an SDK root has, rather than by a path
/// shape, so it works the same under `dart test`, under `flutter test`, and on
/// a CI image that lays Flutter out somewhere else entirely.
String _dartSdkPath() {
  bool isSdk(String path) => File(
    p.join(
      path,
      'lib',
      '_internal',
      'sdk_library_metadata',
      'lib',
      'libraries.dart',
    ),
  ).existsSync();

  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?)
      p.join(root, 'bin', 'cache', 'dart-sdk'),
  ];
  for (
    var directory = p.dirname(Platform.resolvedExecutable);
    directory != p.dirname(directory);
    directory = p.dirname(directory)
  ) {
    candidates
      ..add(directory)
      ..add(p.join(directory, 'dart-sdk'));
  }
  return candidates.firstWhere(
    isSdk,
    orElse: () => throw StateError(
      'no Dart SDK found from ${Platform.resolvedExecutable}; looked in '
      '${candidates.join(', ')}',
    ),
  );
}

/// Whether a member is outside the audit.
///
/// Private members obviously are. `@internal` ones are too, and that is a
/// substantive exemption rather than an escape hatch: the annotation is not a
/// comment, it makes the analyzer refuse the member to anybody outside this
/// package (`invalid_use_of_internal_member`), so an `@internal` member is
/// enforced not-API by the same tool that would have caught the leak. The two
/// that use it both take a pigeon-generated wire type whose own file says not
/// to edit it.
bool _skip(ExecutableElement element) =>
    element.isPrivate || element.metadata.hasInternal;

void _checkExecutable(
  String owner,
  ExecutableElement element,
  void Function(String owner, DartType? type) check,
) {
  check('$owner (returns)', element.returnType);
  for (final parameter in element.formalParameters) {
    check('$owner(${parameter.name ?? '_'})', parameter.type);
  }
  for (final parameter in element.typeParameters) {
    check('$owner (type parameter bound)', parameter.bound);
  }
}

/// Every element a type mentions, following type arguments, function types,
/// record fields and type-parameter bounds all the way down.
Set<Element> _elementsIn(DartType? type, [Set<DartType>? seen]) {
  if (type == null) return const {};
  final visited = seen ?? <DartType>{};
  if (!visited.add(type)) return const {};

  final found = <Element>{};
  switch (type) {
    case InterfaceType():
      final element = type.element;
      found.add(element);
      for (final argument in type.typeArguments) {
        found.addAll(_elementsIn(argument, visited));
      }
    case FunctionType():
      found.addAll(_elementsIn(type.returnType, visited));
      for (final parameter in type.formalParameters) {
        found.addAll(_elementsIn(parameter.type, visited));
      }
      for (final parameter in type.typeParameters) {
        found.addAll(_elementsIn(parameter.bound, visited));
      }
    case TypeParameterType():
      found.addAll(_elementsIn(type.bound, visited));
    case RecordType():
      for (final field in [...type.positionalFields, ...type.namedFields]) {
        found.addAll(_elementsIn(field.type, visited));
      }
    default:
      break;
  }
  // A type written through an alias mentions both, and the alias is just as
  // capable of being private as the thing it names.
  final alias = type.alias;
  if (alias != null) {
    found.add(alias.element);
    for (final argument in alias.typeArguments) {
      found.addAll(_elementsIn(argument, visited));
    }
  }
  return found;
}

bool _isInSrc(Element element) {
  final uri = element.library?.uri.toString();
  return uri != null && uri.startsWith('package:sphere_view/src/');
}

String _shortUri(Element element) =>
    element.library?.uri.toString().replaceFirst('package:sphere_view/', '') ??
    'unknown';
