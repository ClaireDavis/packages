// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json;
import 'dart:html' as html;
import 'dart:math' as math;

import 'src/common.dart';
import 'src/recorder.dart';
export 'src/recorder.dart';

/// Signature for a function that creates a [Recorder].
typedef RecorderFactory = Recorder Function();

/// List of all benchmarks that run in the devicelab.
///
/// When adding a new benchmark, add it to this map. Make sure that the name
/// of your benchmark is unique.
late Map<String, RecorderFactory> _benchmarks;

final LocalBenchmarkServerClient _client = LocalBenchmarkServerClient();

/// Starts a local benchmark client to run [benchmarks].
///
/// Usually used in combination with a benchmark server, which orders the
/// client to run each benchmark in order.
///
/// When used without a server, prompts the user to select a benchmark to
/// run next.
Future<void> runBenchmarks(
  Map<String, RecorderFactory> benchmarks, {
  String initialPage = defaultInitialPage,
}) async {
  // Set local benchmarks.
  _benchmarks = benchmarks;

  // Check if the benchmark server wants us to run a specific benchmark.
  final String nextBenchmark = await _client.requestNextBenchmark();

  if (nextBenchmark == LocalBenchmarkServerClient.kManualFallback) {
    _fallbackToManual(
        'The server did not tell us which benchmark to run next.');
    return;
  }

  await _runBenchmark(nextBenchmark);

  final Uri currentUri = Uri.parse(html.window.location.href);
  // Create a new URI with the current 'page' value set to [initialPage] to
  // ensure the benchmark app is reloaded at the proper location.
  final Uri newUri = Uri(
    scheme: currentUri.scheme,
    host: currentUri.host,
    port: currentUri.port,
    path: initialPage,
  );

  // Reloading the window will trigger the next benchmark to run.
  html.window.location.replace(newUri.toString());
}

Future<void> _runBenchmark(String? benchmarkName) async {
  final RecorderFactory? recorderFactory = _benchmarks[benchmarkName];

  if (recorderFactory == null) {
    _fallbackToManual('Benchmark $benchmarkName not found.');
    return;
  }

  await runZoned<Future<void>>(
    () async {
      final Recorder recorder = recorderFactory();
      final Runner runner = recorder.isTracingEnabled && !_client.isInManualMode
          ? Runner(
              recorder: recorder,
              setUpAllDidRun: () =>
                  _client.startPerformanceTracing(benchmarkName),
              tearDownAllWillRun: _client.stopPerformanceTracing,
            )
          : Runner(recorder: recorder);

      final Profile profile = await runner.run();
      if (!_client.isInManualMode) {
        await _client.sendProfileData(profile);
      } else {
        _printResultsToScreen(profile);
        print(profile); // ignore: avoid_print
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) async {
        if (_client.isInManualMode) {
          parent.print(zone, '[$benchmarkName] $line');
        } else {
          await _client.printToConsole(line);
        }
      },
      handleUncaughtError: (
        Zone self,
        ZoneDelegate parent,
        Zone zone,
        Object error,
        StackTrace stackTrace,
      ) async {
        if (_client.isInManualMode) {
          parent.print(zone, '[$benchmarkName] $error, $stackTrace');
          parent.handleUncaughtError(zone, error, stackTrace);
        } else {
          await _client.reportError(error, stackTrace);
        }
      },
    ),
  );
}

void _fallbackToManual(String error) {
  html.document.body!.appendHtml('''
    <div id="manual-panel">
      <h3>$error</h3>

      <p>Choose one of the following benchmarks:</p>

      <!-- Absolutely position it so it receives the clicks and not the glasspane -->
      <ul style="position: absolute">
        ${_benchmarks.keys.map((String name) => '<li><button id="$name">$name</button></li>').join('\n')}
      </ul>
    </div>
  ''',
      validator: html.NodeValidatorBuilder()
        ..allowHtml5()
        ..allowInlineStyles());

  for (final String benchmarkName in _benchmarks.keys) {
    // Find the button elements added above.
    final html.Element button = html.document.querySelector('#$benchmarkName')!;
    button.addEventListener('click', (_) {
      final html.Element? manualPanel =
          html.document.querySelector('#manual-panel');
      manualPanel?.remove();
      _runBenchmark(benchmarkName);
    });
  }
}

/// Visualizes results on the Web page for manual inspection.
void _printResultsToScreen(Profile profile) {
  final html.BodyElement body = html.document.body!;

  body.innerHtml = '<h2>${profile.name}</h2>';

  profile.scoreData.forEach((String scoreKey, Timeseries timeseries) {
    body.appendHtml('<h2>$scoreKey</h2>');
    body.appendHtml('<pre>${timeseries.computeStats()}</pre>');
    body.append(TimeseriesVisualization(timeseries).render());
  });
}

/// Draws timeseries data and statistics on a canvas.
class TimeseriesVisualization {
  /// Creates a visualization for a [Timeseries].
  TimeseriesVisualization(this._timeseries) {
    _stats = _timeseries.computeStats();
    _canvas = html.CanvasElement();
    _screenWidth = html.window.screen!.width!;
    _canvas.width = _screenWidth;
    _canvas.height = (_kCanvasHeight * html.window.devicePixelRatio).round();
    _canvas.style
      ..width = '100%'
      ..height = '${_kCanvasHeight}px'
      ..outline = '1px solid green';
    _ctx = _canvas.context2D;

    // The amount of vertical space available on the chart. Because some
    // outliers can be huge they can dwarf all the useful values. So we
    // limit it to 1.5 x the biggest non-outlier.
    _maxValueChartRange = 1.5 *
        _stats.samples
            .where((AnnotatedSample sample) => !sample.isOutlier)
            .map<double>((AnnotatedSample sample) => sample.magnitude)
            .fold<double>(0, math.max);
  }

  static const double _kCanvasHeight = 200;

  final Timeseries _timeseries;
  late TimeseriesStats _stats;
  late html.CanvasElement _canvas;
  late html.CanvasRenderingContext2D _ctx;
  late int _screenWidth;

  // Used to normalize benchmark values to chart height.
  late double _maxValueChartRange;

  /// Converts a sample value to vertical canvas coordinates.
  ///
  /// This does not work for horizontal coordinates.
  double _normalized(double value) {
    return _kCanvasHeight * value / _maxValueChartRange;
  }

  /// A utility for drawing lines.
  void drawLine(num x1, num y1, num x2, num y2) {
    _ctx.beginPath();
    _ctx.moveTo(x1, y1);
    _ctx.lineTo(x2, y2);
    _ctx.stroke();
  }

  /// Renders the timeseries into a `<canvas>` and returns the canvas element.
  html.CanvasElement render() {
    _ctx.translate(0, _kCanvasHeight * html.window.devicePixelRatio);
    _ctx.scale(1, -html.window.devicePixelRatio);

    final double barWidth = _screenWidth / _stats.samples.length;
    double xOffset = 0;
    for (int i = 0; i < _stats.samples.length; i++) {
      final AnnotatedSample sample = _stats.samples[i];

      if (sample.isWarmUpValue) {
        // Put gray background behind warm-up samples.
        _ctx.fillStyle = 'rgba(200,200,200,1)';
        _ctx.fillRect(xOffset, 0, barWidth, _normalized(_maxValueChartRange));
      }

      if (sample.magnitude > _maxValueChartRange) {
        // The sample value is so big it doesn't fit on the chart. Paint it purple.
        _ctx.fillStyle = 'rgba(100,50,100,0.8)';
      } else if (sample.isOutlier) {
        // The sample is an outlier, color it light red.
        _ctx.fillStyle = 'rgba(255,50,50,0.6)';
      } else {
        // A non-outlier sample, color it light blue.
        _ctx.fillStyle = 'rgba(50,50,255,0.6)';
      }

      _ctx.fillRect(xOffset, 0, barWidth - 1, _normalized(sample.magnitude));
      xOffset += barWidth;
    }

    // Draw a horizontal solid line corresponding to the average.
    _ctx.lineWidth = 1;
    drawLine(0, _normalized(_stats.average), _screenWidth,
        _normalized(_stats.average));

    // Draw a horizontal dashed line corresponding to the outlier cut off.
    _ctx.setLineDash(<num>[5, 5]);
    drawLine(0, _normalized(_stats.outlierCutOff), _screenWidth,
        _normalized(_stats.outlierCutOff));

    // Draw a light red band that shows the noise (1 stddev in each direction).
    _ctx.fillStyle = 'rgba(255,50,50,0.3)';
    _ctx.fillRect(
      0,
      _normalized(_stats.average * (1 - _stats.noise)),
      _screenWidth,
      _normalized(2 * _stats.average * _stats.noise),
    );

    return _canvas;
  }
}

/// Implements the client REST API for the local benchmark server.
///
/// The local server is optional. If it is not available the benchmark UI must
/// implement a manual fallback. This allows debugging benchmarks using plain
/// `flutter run`.
class LocalBenchmarkServerClient {
  /// This value is returned by [requestNextBenchmark].
  static const String kManualFallback = '__manual_fallback__';

  /// Whether we fell back to manual mode.
  ///
  /// This happens when you run benchmarks using plain `flutter run` rather than
  /// devicelab test harness. The test harness spins up a special server that
  /// provides API for automatically picking the next benchmark to run.
  late bool isInManualMode;

  /// Asks the local server for the name of the next benchmark to run.
  ///
  /// Returns [kManualFallback] if local server is not available (uses 404 as a
  /// signal).
  Future<String> requestNextBenchmark() async {
    final html.HttpRequest request = await _requestXhr(
      '/next-benchmark',
      method: 'POST',
      mimeType: 'application/json',
      sendData: json.encode(_benchmarks.keys.toList()),
    );

    // `kEndOfBenchmarks` is expected when the benchmark server is telling us there are no more benchmarks to run.
    // 404 is expected when the benchmark is run using plain `flutter run`, which does not provide "next-benchmark" handler.
    if (request.responseText == kEndOfBenchmarks || request.status == 404) {
      isInManualMode = true;
      return kManualFallback;
    }

    isInManualMode = false;
    return request.responseText ?? kManualFallback;
  }

  void _checkNotManualMode() {
    if (isInManualMode) {
      throw StateError('Operation not supported in manual fallback mode.');
    }
  }

  /// Asks the local server to begin tracing performance.
  ///
  /// This uses the chrome://tracing tracer, which is not available from within
  /// the page itself, and therefore must be controlled from outside using the
  /// DevTools Protocol.
  Future<void> startPerformanceTracing(String? benchmarkName) async {
    _checkNotManualMode();
    await html.HttpRequest.request(
      '/start-performance-tracing?label=$benchmarkName',
      method: 'POST',
      mimeType: 'application/json',
    );
  }

  /// Stops the performance tracing session started by [startPerformanceTracing].
  Future<void> stopPerformanceTracing() async {
    _checkNotManualMode();
    await html.HttpRequest.request(
      '/stop-performance-tracing',
      method: 'POST',
      mimeType: 'application/json',
    );
  }

  /// Sends the profile data collected by the benchmark to the local benchmark
  /// server.
  Future<void> sendProfileData(Profile profile) async {
    _checkNotManualMode();
    final html.HttpRequest request = await html.HttpRequest.request(
      '/profile-data',
      method: 'POST',
      mimeType: 'application/json',
      sendData: json.encode(profile.toJson()),
    );
    if (request.status != 200) {
      throw Exception('Failed to report profile data to benchmark server. '
          'The server responded with status code ${request.status}.');
    }
  }

  /// Reports an error to the benchmark server.
  ///
  /// The server will halt the devicelab task and log the error.
  Future<void> reportError(dynamic error, StackTrace stackTrace) async {
    _checkNotManualMode();
    await html.HttpRequest.request(
      '/on-error',
      method: 'POST',
      mimeType: 'application/json',
      sendData: json.encode(<String, dynamic>{
        'error': '$error',
        'stackTrace': '$stackTrace',
      }),
    );
  }

  /// Reports a message about the demo to the benchmark server.
  Future<void> printToConsole(String report) async {
    _checkNotManualMode();
    await html.HttpRequest.request(
      '/print-to-console',
      method: 'POST',
      mimeType: 'text/plain',
      sendData: report,
    );
  }

  /// This is the same as calling [html.HttpRequest.request] but it doesn't
  /// crash on 404, which we use to detect `flutter run`.
  Future<html.HttpRequest> _requestXhr(
    String url, {
    required String method,
    required String mimeType,
    required dynamic sendData,
  }) {
    final Completer<html.HttpRequest> completer = Completer<html.HttpRequest>();
    final html.HttpRequest xhr = html.HttpRequest();
    xhr.open(method, url, async: true);
    xhr.overrideMimeType(mimeType);
    xhr.onLoad.listen((html.ProgressEvent e) {
      completer.complete(xhr);
    });
    xhr.onError.listen(completer.completeError);
    xhr.send(sendData);
    return completer.future;
  }
}
