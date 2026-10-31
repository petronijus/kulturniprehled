import 'package:integration_test/integration_test_driver.dart';

/// Host side of the performance benchmarks in `integration_test/`: each
/// `watchPerformance` report (frame build/raster percentiles, missed frames)
/// is written to `build/<reportKey>.json`.
Future<void> main() {
  return integrationDriver(
    responseDataCallback: (Map<String, dynamic>? data) async {
      if (data == null) {
        return;
      }
      for (final MapEntry<String, dynamic> entry in data.entries) {
        await writeResponseData(<String, dynamic>{
          entry.key: entry.value,
        }, testOutputFilename: entry.key);
      }
    },
  );
}
