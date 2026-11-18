import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const Datalogger9App());

class Datalogger9App extends StatelessWidget {
  const Datalogger9App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Datalogger 9 assi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
        scaffoldBackgroundColor: const Color(0xFFF4F6F9),
        useMaterial3: true,
      ),
      home: const DataloggerHome(),
    );
  }
}

class ChartDef {
  final String title;
  final List<int> indices;
  final List<String> names;
  final int dp;
  final bool rel;
  ChartDef(this.title, this.indices, this.names, {this.dp = 2, this.rel = false});
}

class SdFileItem {
  final String name;
  final int size;
  SdFileItem(this.name, this.size);
}

class DataloggerHome extends StatefulWidget {
  const DataloggerHome({super.key});
  @override
  State<DataloggerHome> createState() => _DataloggerHomeState();
}

class _DataloggerHomeState extends State<DataloggerHome> {
  static final Guid svcUuid = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
  static final Guid cmdUuid = Guid("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
  static final Guid chrUuid = Guid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
  static final Guid filUuid = Guid("6e400004-b5a3-f393-e0a9-e50e24dcca9e");

  BluetoothDevice? device;
  BluetoothCharacteristic? cmdChar;
  StreamSubscription? pktSub, filSub, connSub, scanSub;

  bool connected = false;
  String statusText = "Pronto";
  String deviceName = "Datalogger9";

  // Buffer riassemblaggio pacchetti 148 byte
  final Uint8List asm = Uint8List(148);
  int got = 0;

  // Dati correnti (36 valori: 35 float + quotaRel_m)
  List<double> curV = List.filled(36, 0.0);
  int fl = 0, fl2 = 0, prevFl = 0, shocks = 0;
  double? alt0;
  bool hasData = false;

  // Storico grafici (ultimi 300 campioni = 30s a 10Hz)
  final List<List<double>> buf = [];
  bool paused = false;
  double? curPos; // 0.0 .. 1.0

  // Registrazione telefono
  bool recOn = false;
  final List<String> recLines = [];
  List<FileSystemEntity> savedCsvs = [];

  // Gestione file microSD
  String? fmode;
  final List<int> fbytes = [];
  SdFileItem? fcur;
  List<SdFileItem> sdFiles = [];
  String sdListStatus = "";
  String sdDownloadProgress = "";

  // Controlli parametri
  bool autoStart = false;
  int rangeG = 16;
  int rateHz = 100;
  final TextEditingController shockCtrl = TextEditingController(text: "3");

  final List<ChartDef> charts = [
    ChartDef("Accelerazione (g)", [0, 1, 2], ["X", "Y", "Z"]),
    ChartDef("Giroscopio (°/s)", [3, 4, 5], ["X", "Y", "Z"]),
    ChartDef("Magnetometro (µT)", [6, 7, 8], ["X", "Y", "Z"]),
    ChartDef("Orientamento (°)", [12, 13, 14], ["Roll", "Pitch", "Yaw"], dp: 1),
    ChartDef("Temperatura (°C)", [9], [""], dp: 1),
    ChartDef("Pressione (hPa)", [10], [""], dp: 1),
    ChartDef("Quota relativa (m)", [35], [""], dp: 1, rel: true),
    ChartDef("Vibrazione RMS (g)", [11], [""], dp: 3),
    ChartDef("Frequenza dominante (Hz)", [16], [""], dp: 0),
    ChartDef("WT1 accelerazione (g)", [17, 18, 19], ["X", "Y", "Z"]),
    ChartDef("WT1 giroscopio (°/s)", [20, 21, 22], ["X", "Y", "Z"], dp: 1),
    ChartDef("WT1 angoli (°)", [23, 24, 25], ["Roll", "Pitch", "Yaw"], dp: 1),
    ChartDef("WT2 accelerazione (g)", [26, 27, 28], ["X", "Y", "Z"]),
    ChartDef("WT2 giroscopio (°/s)", [29, 30, 31], ["X", "Y", "Z"], dp: 1),
    ChartDef("WT2 angoli (°)", [32, 33, 34], ["Roll", "Pitch", "Yaw"], dp: 1),
  ];

  @override
  void initState() {
    super.initState();
    _refreshSavedFiles();
  }

  @override
  void dispose() {
    pktSub?.cancel();
    filSub?.cancel();
    connSub?.cancel();
    scanSub?.cancel();
    device?.disconnect();
    super.dispose();
  }

  int _calcPct(double v) {
    const t = [[3.3, 0], [3.5, 5], [3.7, 20], [3.8, 45], [3.9, 65], [4.0, 80], [4.1, 92], [4.2, 100]];
    if (v <= t[0][0]) return 0;
    for (int i = 1; i < t.length; i++) {
      if (v <= t[i][0]) {
        final a = t[i - 1], b = t[i];
        return (a[1] + (b[1] - a[1]) * (v - a[0]) / (b[0] - a[0])).round();
      }
    }
    return 100;
  }
  Future<void> _scanAndConnect() async {
    if (connected) {
      await device?.disconnect();
      return;
    }
    setState(() => statusText = "Ricerca Datalogger9...");
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Seleziona Datalogger9", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            SizedBox(
              height: 220,
              child: StreamBuilder<List<ScanResult>>(
                stream: FlutterBluePlus.scanResults,
                builder: (c, snap) {
                  final list = snap.data ?? [];
                  if (list.isEmpty) return const Center(child: Text("Scansione dispositivi BLE..."));
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) {
                      final r = list[i];
                      final name = r.device.platformName.isNotEmpty ? r.device.platformName : "Dispositivo BLE";
                      return ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(name),
                        subtitle: Text("${r.device.remoteId} (${r.rssi} dBm)"),
                        trailing: ElevatedButton(
                          onPressed: () async {
                            await FlutterBluePlus.stopScan();
                            if (ctx.mounted) Navigator.pop(ctx);
                            _connect(r.device);
                          },
                          child: const Text("Connetti"),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect(BluetoothDevice dev) async {
    try {
      setState(() => statusText = "Connessione...");
      await dev.connect();
      connSub?.cancel();
      connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            connected = false;
            device = null;
            cmdChar = null;
            statusText = "Disconnesso";
          });
        }
      });

      final services = await dev.discoverServices();
      BluetoothCharacteristic? cCmd, cChr, cFil;
      for (var s in services) {
        if (s.uuid == svcUuid) {
          for (var c in s.characteristics) {
            if (c.uuid == cmdUuid) cCmd = c;
            if (c.uuid == chrUuid) cChr = c;
            if (c.uuid == filUuid) cFil = c;
          }
        }
      }

      if (cChr != null) {
        await cChr.setNotifyValue(true);
        pktSub?.cancel();
        pktSub = cChr.onValueReceived.listen(_onPkt);
      }
      if (cFil != null) {
        await cFil.setNotifyValue(true);
        filSub?.cancel();
        filSub = cFil.onValueReceived.listen(_onFile);
      }

      setState(() {
        device = dev;
        cmdChar = cCmd;
        connected = true;
        deviceName = dev.platformName.isNotEmpty ? dev.platformName : "Datalogger9";
        statusText = "Connesso a $deviceName";
      });
    } catch (e) {
      setState(() => statusText = "Errore connessione: $e");
    }
  }

  void _onPkt(List<int> d) {
    if (d.isEmpty) return;
    int q = d[0];
    if (q == 0) got = 0;
    if (q * 19 != got) return;
    for (int i = 1; i < d.length && got < 148; i++) {
      asm[got++] = d[i];
    }
    if (got >= 148) {
      _onData(ByteData.sublistView(asm));
    }
  }

  void _onData(ByteData d) {
    final v = List<double>.filled(36, 0.0);
    for (int i = 0; i < 35; i++) {
      v[i] = d.getFloat32(4 + i * 4, Endian.little);
    }
    int f1 = d.getUint8(144);
    int f2 = d.getUint8(145);
    double ab = 44330.0 * (1.0 - pow(v[10] / 1013.25, 0.1903));
    alt0 ??= ab;
    v[35] = ab;

    buf.add(v);
    if (buf.length > 600) buf.removeAt(0);

    if (recOn) {
      int ms = d.getUint32(0, Endian.little);
      final vals = v.sublist(0, 35).map((x) => x.toStringAsFixed(3)).join(",");
      recLines.add("$ms,$vals,${(ab - alt0!).toStringAsFixed(2)}");
    }

    if ((f1 & 8) != 0 && (prevFl & 8) == 0) {
      shocks++;
    }
    prevFl = f1;

    if (!paused && mounted) {
      setState(() {
        hasData = true;
        curV = v;
        fl = f1;
        fl2 = f2;
        autoStart = (f1 & 2) != 0;
      });
    }
  }

  Future<void> _tx(List<int> bytes) async {
    if (cmdChar == null) return;
    try {
      await cmdChar!.write(bytes, withoutResponse: false);
    } catch (e) {
      setState(() => statusText = "Errore comando: $e");
    }
  }

  void _onFile(List<int> d) {
    if (d.length == 1 && d[0] == 4) {
      _endFile();
      return;
    }
    fbytes.addAll(d);
    if (fmode == "file" && fcur != null && mounted) {
      int p = min(100, (fbytes.length / fcur!.size * 100).round());
      setState(() => sdDownloadProgress = "${fcur!.name}: $p%");
    }
  }

  Future<void> _endFile() async {
    String txt = String.fromCharCodes(fbytes);
    String? m = fmode;
    fmode = null;
    if (m == "list") {
      final rows = txt.trim().split("\n").where((l) => l.isNotEmpty).map((l) => l.split(",")).toList();
      setState(() {
        sdFiles = rows.map((r) => SdFileItem(r[0], r.length > 1 ? (int.tryParse(r[1]) ?? 1) : 1)).toList();
        sdListStatus = sdFiles.isEmpty ? "Nessun file sulla microSD" : "";
      });
    } else if (m == "file" && fcur != null) {
      final dir = await getApplicationDocumentsDirectory();
      final f = File("${dir.path}/${fcur!.name}");
      await f.writeAsString(txt);
      setState(() => sdDownloadProgress = "Salvato: ${fcur!.name}");
      _refreshSavedFiles();
    }
  }

  Future<void> _toggleRec() async {
    if (recOn) {
      final dir = await getApplicationDocumentsDirectory();
      final f = File("${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.csv");
      await f.writeAsString(recLines.join("\n"));
      setState(() {
        recOn = false;
        statusText = "Sessione salvata";
      });
      _refreshSavedFiles();
    } else {
      recLines.clear();
      recLines.add("ms,ax,ay,az,gx,gy,gz,mx,my,mz,tempC,hPa,vibRMS,roll,pitch,yaw,batV,fHz,wt1_ax,wt1_ay,wt1_az,wt1_gx,wt1_gy,wt1_gz,wt1_roll,wt1_pitch,wt1_yaw,wt2_ax,wt2_ay,wt2_az,wt2_gx,wt2_gy,wt2_gz,wt2_roll,wt2_pitch,wt2_yaw,quotaRel_m");
      setState(() => recOn = true);
    }
  }

  Future<void> _refreshSavedFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    setState(() => savedCsvs = dir.listSync().where((f) => f.path.endsWith(".csv")).toList());
  }
  @override
  Widget build(BuildContext context) {
    bool sd = (fl & 4) != 0;
    bool lg = (fl & 1) != 0;
    bool rtcOk = (fl & 16) != 0;
    bool lowBat = (fl & 32) != 0;
    bool cal = (fl & 64) != 0;
    bool wt1 = (fl & 128) != 0;
    bool wt2 = (fl2 & 1) != 0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        title: const Text("Datalogger 9 assi", style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_searching),
            onPressed: _scanAndConnect,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // Stato connessione e avvisi
            Card(
              color: connected ? Colors.green.shade50 : Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(connected ? "Connesso ($deviceName)" : "Non connesso", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                              Text(statusText, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                            ],
                          ),
                        ),
                        ElevatedButton(onPressed: _scanAndConnect, child: Text(connected ? "Scollega" : "Connetti")),
                      ],
                    ),
                    if (lowBat)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text("Batteria scarica: ricarica il sensore", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    if (shocks > 0)
                      InkWell(
                        onTap: () => setState(() => shocks = 0),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text("⚠ Urti rilevati: $shocks (tocca per azzerare)", style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // 4 Metriche principali
            Row(
              children: [
                Expanded(child: _metricBox("Temperatura", hasData ? "${curV[9].toStringAsFixed(1)} °C" : "– °C")),
                const SizedBox(width: 8),
                Expanded(child: _metricBox("Pressione", hasData ? "${curV[10].toStringAsFixed(1)} hPa" : "– hPa")),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _metricBox("Batteria", !hasData ? "–" : (curV[15] < 1 ? "non misurata" : "${_calcPct(curV[15])}% (${curV[15].toStringAsFixed(2)} V)"))),
                const SizedBox(width: 8),
                Expanded(child: _metricBox("Quota relativa", hasData && alt0 != null ? "${(curV[35] - alt0!).toStringAsFixed(1)} m" : "– m")),
              ],
            ),
            const SizedBox(height: 8),

            // Stato WT9011DCL 1 e 2
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("WT9011DCL  1: ${wt1 ? 'connesso' : 'no'}   2: ${wt2 ? 'connesso' : 'no'}", style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Registrazione su microSD: ${!sd ? 'non rilevata' : (lg ? '● In registrazione' : 'Ferma')}", style: TextStyle(fontWeight: FontWeight.bold, color: lg ? Colors.green.shade700 : Colors.black87, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: ElevatedButton(onPressed: (!connected || !sd || lg) ? null : () => _tx([1]), child: const Text("Avvia SD"))),
                        const SizedBox(width: 8),
                        Expanded(child: OutlinedButton(onPressed: (!connected || !lg) ? null : () => _tx([0]), child: const Text("Ferma SD"))),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Avvio automatico all’accensione", style: TextStyle(fontSize: 13)),
                      subtitle: const Text("L’interruttore REC sul sensore avvia e ferma la registrazione anche senza telefono.", style: TextStyle(fontSize: 11)),
                      value: autoStart,
                      onChanged: (!connected || !sd) ? null : (v) => _tx([v ? 2 : 3]),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Tutti i 15 Grafici (inclusi Altimetria, Curva Termica, WT1 e WT2)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(child: Text("Tocca un grafico per il cursore, trascina per scorrere (va in pausa).", style: TextStyle(fontSize: 11, color: Colors.black54))),
                        if (paused) TextButton(onPressed: () => setState(() { paused = false; curPos = null; }), child: const Text("Riprendi")),
                      ],
                    ),
                    ...charts.map((c) => _buildChartWidget(c)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Orologio e Calibrazione
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rtcOk ? "Orologio RTC: impostato" : "Orologio RTC: assente o da impostare", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    if (cal) const Text("Calibrazione in corso…", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text("Accel/giro: sensore fermo e in piano (1,5 s). Magnetometro: ruotalo in tutte le direzioni per 15 s.", style: TextStyle(fontSize: 11)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: !connected ? null : () {
                            int e = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + DateTime.now().timeZoneOffset.inSeconds;
                            _tx([4, e & 255, (e >> 8) & 255, (e >> 16) & 255, (e >> 24) & 255]);
                          },
                          child: const Text("Sincronizza Ora", style: TextStyle(fontSize: 12)),
                        ),
                        OutlinedButton(onPressed: !connected ? null : () => _tx([5]), child: const Text("Calibra Accel/Giro", style: TextStyle(fontSize: 12))),
                        OutlinedButton(onPressed: !connected ? null : () => _tx([6]), child: const Text("Calibra Mag", style: TextStyle(fontSize: 12))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // File sulla microSD
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("File sulla microSD", style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text("Il Bluetooth è lento (pochi KB/s): adatto a file brevi. Non disponibile durante la registrazione.", style: TextStyle(fontSize: 11, color: Colors.black54)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: (!connected || !sd || lg) ? null : () {
                        setState(() { fmode = "list"; fbytes.clear(); sdListStatus = "Lettura…"; });
                        _tx([7]);
                      },
                      icon: const Icon(Icons.sd_storage, size: 18),
                      label: const Text("Aggiorna lista file microSD"),
                    ),
                    if (sdListStatus.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sdListStatus, style: const TextStyle(fontSize: 12))),
if (sdDownloadProgress.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sdDownloadProgress, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue))),
...sdFiles.map((f) => ListTile(
dense: true,
contentPadding: EdgeInsets.zero,
title: Text("${f.name} · ${(f.size / 1024).round()} KB"),
trailing: ElevatedButton(
onPressed: () {
setState(() { fcur = f; fmode = "file"; fbytes.clear(); sdDownloadProgress = "${f.name}: 0%"; });
_tx([8, ...f.name.codeUnits]);
},
child: const Text("Scarica"),
),
)),
],
),
),
),
const SizedBox(height: 8),
// Parametri del sensore
Card(
child: Padding(
padding: const EdgeInsets.all(12),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
const Text("Parametri del sensore", style: TextStyle(fontWeight: FontWeight.bold)),
const SizedBox(height: 8),
Row(
children: [
Expanded(
child: DropdownButtonFormField(
value: rangeG,
decoration: const InputDecoration(labelText: "Fondo scala (g)", border: OutlineInputBorder(), isDense: true),
items: [2, 4, 8, 16].map((g) => DropdownMenuItem(value: g, child: Text("±$g g"))).toList(),
onChanged: (v) => setState(() => rangeG = v ?? 16),
),
),
const SizedBox(width: 8),
Expanded(
child: DropdownButtonFormField(
value: rateHz,
decoration: const InputDecoration(labelText: "Frequenza (Hz)", border: OutlineInputBorder(), isDense: true),
items: [50, 100, 200, 500].map((h) => DropdownMenuItem(value: h, child: Text("$h Hz"))).toList(),
onChanged: (v) => setState(() => rateHz = v ?? 100),
),
),
],
),
const SizedBox(height: 8),
Row(
children: [
Expanded(child: TextField(controller: shockCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Soglia urto (g)", border: OutlineInputBorder(), isDense: true))),
const SizedBox(width: 8),
ElevatedButton(
onPressed: !connected ? null : () {
int g = (int.tryParse(shockCtrl.text) ?? 3).clamp(1, 25);
_tx([10, rangeG, rateHz & 255, rateHz >> 8, g * 10]);
setState(() => statusText = "Parametri salvati: il sensore si riavvia");
},
child: const Text("Applica"),
),
],
),
],
),
),
),
const SizedBox(height: 8),
// Registrazione sul telefono
Card(
child: Padding(
padding: const EdgeInsets.all(12),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
const Text("Registrazione sul telefono (10 campioni/s)", style: TextStyle(fontWeight: FontWeight.bold)),
const SizedBox(height: 8),
Row(
mainAxisAlignment: MainAxisAlignment.spaceBetween,
children: [
Text("${recLines.isEmpty ? 0 : recLines.length - 1} campioni", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
ElevatedButton(
style: ElevatedButton.styleFrom(backgroundColor: recOn ? Colors.red : const Color(0xFF1E3A8A), foregroundColor: Colors.white),
onPressed: _toggleRec,
child: Text(recOn ? "Ferma e Salva" : "Registra"),
),
],
),
const Divider(height: 20),
const Text("Sessioni salvate", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
if (savedCsvs.isEmpty)
const Padding(padding: EdgeInsets.only(top: 4), child: Text("Nessuna sessione salvata sul telefono.", style: TextStyle(fontSize: 12, color: Colors.black54)))
else
...savedCsvs.map((f) => ListTile(
dense: true,
contentPadding: EdgeInsets.zero,
title: Text(f.path.split("/").last, style: const TextStyle(fontSize: 12)),
trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 18), onPressed: () { f.deleteSync(); _refreshSavedFiles(); }),
)),
],
),
),
),
],
),
),
);
}
Widget _metricBox(String label, String val) {
return Card(
child: Padding(
padding: const EdgeInsets.all(10),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
const SizedBox(height: 2),
Text(val, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
],
),
),
);
}
Widget _buildChartWidget(ChartDef c) {
const cols = [Color(0xFFE5484D), Color(0xFF30A46C), Color(0xFF3E63DD)];
double o = c.rel ? (alt0 ?? 0.0) : 0.0;
int ci = buf.isEmpty ? -1 : (curPos == null ? buf.length - 1 : (curPos! * (buf.length - 1)).round().clamp(0, buf.length - 1));
return Padding(
padding: const EdgeInsets.only(top: 10),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Row(
mainAxisAlignment: MainAxisAlignment.spaceBetween,
children: [
Text(c.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
if (ci >= 0)
Row(
children: List.generate(c.indices.length, (j) {
int k = c.indices[j];
Color col = cols[c.indices.length > 1 ? j : 2];
return Padding(
padding: const EdgeInsets.only(left: 6),
child: Text("${c.names[j]} ${(buf[ci][k] - o).toStringAsFixed(c.dp)}", style: TextStyle(fontSize: 11, color: col, fontWeight: FontWeight.bold)),
);
}),
),
],
),
const SizedBox(height: 4),
LayoutBuilder(
builder: (ctx, box) => GestureDetector(
onTapDown: (d) => setState(() { paused = true; curPos = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0); }),
onHorizontalDragUpdate: (d) => setState(() { paused = true; curPos = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0); }),
child: Container(
height: 95,
width: double.infinity,
decoration: BoxDecoration(color: const Color(0xFFFAFAFA), border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(6)),
child: CustomPaint(painter: _MultiLinePainter(buf, c, o, curPos)),
),
),
),
],
),
);
}
}
class _MultiLinePainter extends CustomPainter {
final List<List> buf;
final ChartDef c;
final double offset;
final double? curPos;
_MultiLinePainter(this.buf, this.c, this.offset, this.curPos);
@override
void paint(Canvas canvas, Size size) {
const cols = [Color(0xFFE5484D), Color(0xFF30A46C), Color(0xFF3E63DD)];
if (buf.length < 2) return;
double lo = double.infinity, hi = -double.infinity;
for (var row in buf) {
for (int k in c.indices) {
double val = row[k] - offset;
if (val < lo) lo = val;
if (val > hi) hi = val;
}
}
if (hi - lo < 1e-6) { hi += 0.5; lo -= 0.5; }
double pad = (hi - lo) * 0.1;
lo -= pad; hi += pad;
for (int j = 0; j < c.indices.length; j++) {
int k = c.indices[j];
final paint = Paint()..color = cols[c.indices.length > 1 ? j : 2]..strokeWidth = 1.8..style = PaintingStyle.stroke;
final path = Path();
for (int i = 0; i < buf.length; i++) {
double px = (i / (buf.length - 1)) * size.width;
double py = size.height - ((buf[i][k] - offset - lo) / (hi - lo)) * size.height;
if (i == 0) path.moveTo(px, py); else path.lineTo(px, py);
}
canvas.drawPath(path, paint);
}
if (curPos != null) {
double cx = curPos! * size.width;
canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), Paint()..color = Colors.black54..strokeWidth = 1.2);
}
}
@override
bool shouldRepaint(covariant _MultiLinePainter oldDelegate) => true;
}
