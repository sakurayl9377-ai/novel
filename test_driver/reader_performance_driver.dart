import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      final summary = data?['reader_performance_summary'];
      if (summary == null) {
        throw StateError('Reader performance summary was not reported.');
      }
      final output = File(
        'build/test-artifacts/reader-performance-summary.json',
      );
      await output.parent.create(recursive: true);
      final encoded = const JsonEncoder.withIndent('  ').convert(summary);
      await output.writeAsString('$encoded\n');
      stdout.writeln('Reader performance summary: ${output.absolute.path}');
      stdout.writeln(encoded);
    },
  );
}
