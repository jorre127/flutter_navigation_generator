import 'package:code_builder/code_builder.dart';
import 'package:collection/collection.dart';
import 'package:flutter_navigation_generator/src/extensions/navigation_type_extension.dart';
import 'package:flutter_navigation_generator/src/models/importable_type.dart';
import 'package:flutter_navigation_generator/src/models/route_config.dart';
import 'package:flutter_navigation_generator/src/utils/case_utils.dart';
import 'package:flutter_navigation_generator/src/utils/importable_type_string_converter.dart';
import 'package:flutter_navigation_generator/src/utils/route_config_extension.dart';
import 'package:flutter_navigation_generator/src/utils/utils.dart';
import 'package:flutter_navigation_generator_annotations/flutter_navigation_generator_annotations.dart';

class RouteBuilder {
  final Set<RouteConfig> routes;
  final ImportableType? pageType;
  final Uri? targetFile;

  RouteBuilder({
    required this.routes,
    required this.pageType,
    required this.targetFile,
  });

  Iterable<Method> generate() {
    final methodRoutes = routes.where((element) => element.generateMethod);
    final dialogRoutes = <RouteConfig>[];
    final bottomSheetRoutes = <RouteConfig>[];
    final pageRoutes = <RouteConfig>[];
    for (final route in methodRoutes) {
      switch (route.navigationType) {
        case NavigationType.dialog:
          dialogRoutes.add(route);
          break;
        case NavigationType.bottomSheet:
          bottomSheetRoutes.add(route);
          break;
        default:
          pageRoutes.add(route);
      }
    }
    return <Method>[]
        .followedBy(_generatePageRoutes(pageRoutes))
        .followedBy(_generateDialogRoutes(dialogRoutes))
        .followedBy(_generateBottomSheetRoutes(bottomSheetRoutes))
        .followedBy(_generateGenericRoutes());
  }

  Method _generateMethod({
    required RouteConfig route,
    required Code body,
    required String namePrefix,
    bool isLambda = true,
    bool isAsync = true,
  }) {
    final String name;
    if (route.methodNameIsDefinedByAnnotation) {
      name = route.methodName;
    } else {
      name =
          '$namePrefix${CaseUtil(route.methodName.replaceAll(RegExp(':[a-zA-Z0-9]*'), '')).upperCamelCase}';
    }
    return Method(
      (b) => b
        ..name = name
        ..lambda = isLambda
        ..modifier = isAsync ? MethodModifier.async : null
        ..optionalParameters.addAll(
          route.parameters.map(
            (p) => Parameter(
              (b) => b
                ..name = p.argumentName
                ..named = true
                ..required = p.isRequired && route.defaultValues[p.name] == null
                ..defaultTo = route.defaultValues[p.name] != null
                    ? Reference(route.defaultValues[p.name]! as String).code
                    : null
                ..type = typeRefer(p),
            ),
          ),
        )
        ..returns = typeRefer(
          route.returnType,
          forceNullable: true,
          forceFuture: isAsync,
        )
        ..body = body,
    );
  }

  Iterable<Method> _generatePageRoutes(List<RouteConfig> routes) {
    return routes.map(
      (route) {
        Expression path;
        final parameters = route.routeName.parametersFromRouteName;
        if (route.routeNameContainsParameters) {
          path = Reference('RouteNames.${route.asRouteName}').call(
              [],
              (parameters.asMap().map((_, parameter) {
                final argument = route.parameters
                    .firstWhereOrNull((element) => element.name == parameter);
                if (argument == null) return MapEntry(parameter, null);
                return MapEntry(
                    parameter,
                    Reference(ImportableTypeStringConverter.convertToString(
                        argument)));
              })
                    ..removeWhere((key, value) => value == null))
                  .cast());
        } else {
          path = Reference('RouteNames.${route.asRouteName}');
        }
        final queryParameters = route.parameters
            .where((element) =>
                element.className != 'Key' &&
                !parameters.contains(element.argumentName))
            .toList()
            .asMap()
            .map((_, p) {
          final stringValue = ImportableTypeStringConverter.convertToString(p);
          return MapEntry(
            "'${p.argumentName}'",
            (p.isNullable && p.isCustomClass)
                ? '${p.name} == null ? null : $stringValue'
                : stringValue,
          );
        });

        final queryParametersRemoveNull = route.parameters.any((element) =>
                element.className != 'Key' &&
                !parameters.contains(element.argumentName) &&
                element.isNullable)
            ? '..removeWhere((_, v) => v == null)'
            : '';

        final bodyCall = TypeReference(
          (b) => b
            ..symbol =
                'navigatorKey.currentState?.${route.navigationType.navigatorMethod}'
            ..types.addAll(
              [
                const Reference('dynamic'),
                if (route.navigationType == NavigationType.pushReplacement ||
                    route.navigationType == NavigationType.popAndPush ||
                    route.navigationType ==
                        NavigationType.restorablePushReplacement ||
                    route.navigationType ==
                        NavigationType.restorablePopAndPush) ...[
                  const Reference('dynamic'),
                ],
              ],
            ),
        ).call(
          [
            queryParameters.isEmpty
                ? path
                : const Reference(
                    'Uri',
                    'dart:core',
                  ).call(
                    [],
                    {
                      'path': path,
                      'queryParameters': Reference(
                          '$queryParameters$queryParametersRemoveNull'),
                    },
                  ).property('toString()'),
            if (route.navigationType == NavigationType.pushAndReplaceAll ||
                route.navigationType ==
                    NavigationType.restorablePushAndReplaceAll) ...[
              const Reference('(_) => false'),
            ],
          ],
          {
            'arguments': Reference(
                '${route.parameters.asMap().map((_, p) => MapEntry("'${p.argumentName}'", p.argumentName))}'),
          },
        );
        Code body;
        if (route.returnType != null) {
          body = Block((b) => b
            ..statements.add(
                declareFinal('result', type: const Reference('dynamic'))
                    .assign(bodyCall.awaited)
                    .statement)
            ..statements.add(const Reference('result')
                .asA(typeRefer(route.returnType, forceNullable: true))
                .returned
                .statement));
        } else {
          body = bodyCall.code;
        }
        return _generateMethod(
          route: route,
          namePrefix: 'goTo',
          isAsync: route.navigationType.isAsync || route.returnType != null,
          isLambda: route.returnType == null,
          body: body,
        );
      },
    );
  }

  Method _generateBottomSheetOrDialogRoute({
    required RouteConfig route,
    required String namePrefix,
    required String bodyCall,
  }) {
    return _generateMethod(
      route: route,
      namePrefix: namePrefix,
      body: TypeReference(
        (b) => b
          ..symbol = bodyCall
          ..types.add(route.returnType == null
              ? const Reference('dynamic')
              : typeRefer(route.returnType!)),
      ).call(
        [],
        {
          'widget': Reference(
            route.constructorName == route.routeWidget.className ||
                    route.constructorName.isEmpty
                ? route.routeWidget.className
                : '${route.routeWidget.className}.${route.constructorName}',
            typeRefer(route.routeWidget).url,
          ).call(
              [],
              route.parameters.asMap().map((_, p) =>
                  MapEntry(p.argumentName, Reference(p.argumentName)))),
        },
      ).code,
    );
  }

  Iterable<Method> _generateDialogRoutes(List<RouteConfig> routes) {
    return routes.map((route) => _generateBottomSheetOrDialogRoute(
          route: route,
          namePrefix: 'showDialog',
          bodyCall: 'showCustomDialog',
        ));
  }

  Iterable<Method> _generateBottomSheetRoutes(List<RouteConfig> routes) {
    return routes.map((route) => _generateBottomSheetOrDialogRoute(
          route: route,
          namePrefix: 'showSheet',
          bodyCall: 'showBottomSheet',
        ));
  }

  Iterable<Method> _generateGenericRoutes() => [
        Method(
          (b) => b
            ..name = 'goBack'
            ..lambda = true
            ..returns = const Reference('void')
            ..body =
                const Reference('navigatorKey.currentState?.pop').call([]).code,
        ),
        Method(
          (b) => b
            ..name = 'goBackWithResult'
            ..lambda = true
            ..types.add(const Reference('T'))
            ..optionalParameters.add(Parameter(
              (b) => b
                ..name = 'result'
                ..named = true
                ..type = const Reference('T?'),
            ))
            ..returns = const Reference('void')
            ..body = const Reference('navigatorKey.currentState?.pop')
                .call([const Reference('result')]).code,
        ),
        Method(
          (b) => b
            ..name = 'popUntil'
            ..lambda = true
            ..requiredParameters.add(Parameter(
              (b) => b
                ..name = 'predicate'
                ..type = FunctionType((b) => b
                  ..returnType = const Reference('bool')
                  ..requiredParameters.add(const Reference('Route<dynamic>'))),
            ))
            ..returns = const Reference('void')
            ..body = const Reference('navigatorKey.currentState?.popUntil')
                .call([const Reference('predicate')]).code,
        ),
        Method(
          (b) => b
            ..name = 'goBackTo'
            ..lambda = true
            ..requiredParameters.add(Parameter((b) => b
              ..name = 'routeName'
              ..type = const Reference('String')))
            ..returns = const Reference('void')
            ..body = const Reference('popUntil').call([
              const Reference('(route) => route.settings.name == routeName'),
            ]).code,
        ),
        Method(
          (b) => b
            ..name = 'showCustomDialog'
            ..lambda = true
            ..modifier = MethodModifier.async
            ..types.add(const Reference('T'))
            ..optionalParameters.add(Parameter(
              (b) => b
                ..name = 'widget'
                ..named = true
                ..type = const Reference('Widget?'),
            ))
            ..returns = const Reference('Future<T?>')
            ..body = const Reference('showDialog<T>').call([], {
              'context': const Reference('navigatorKey.currentContext!'),
              'builder':
                  const Reference('(_) => widget ?? const SizedBox.shrink()'),
            }).code,
        ),
        Method(
          (b) => b
            ..name = 'showBottomSheet'
            ..lambda = true
            ..modifier = MethodModifier.async
            ..types.add(const Reference('T'))
            ..optionalParameters.add(Parameter(
              (b) => b
                ..name = 'widget'
                ..named = true
                ..type = const Reference('Widget?'),
            ))
            ..returns = const Reference('Future<T?>')
            ..body = const Reference('showModalBottomSheet<T>').call([], {
              'context': const Reference('navigatorKey.currentContext!'),
              'builder':
                  const Reference('(_) => widget ?? const SizedBox.shrink()'),
            }).code,
        ),
      ];
}
