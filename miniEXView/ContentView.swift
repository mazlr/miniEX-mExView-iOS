import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel; @State private var showConnection = false; @State private var showAbout = false; @State private var shareURL: URL?
    var body: some View {
        NavigationView { TabView {
            RemoteView().tabItem { Label("Ovládání", systemImage: "display") }
            SettingsView().tabItem { Label("Přístroj", systemImage: "slider.horizontal.3") }
            DataView(shareURL: $shareURL).tabItem { Label("Data", systemImage: "tablecells") }
            DiagnosticsView().tabItem { Label("Diagnostika", systemImage: "waveform.path.ecg") }
        }.navigationTitle("miniEX mExView").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu {
            Button("Připojení") { showConnection = true }; Button("O aplikaci") { showAbout = true }; Button("Offline demo") { model.demo() }; Divider(); Button(model.isConnected ? "Odpojit" : "Připojit přes Wi‑Fi") { model.isConnected ? model.disconnect() : model.connect() }
        } label: { Image(systemName: "ellipsis.circle") } } }.sheet(isPresented: $showConnection) { ConnectionView() }.sheet(isPresented: $showAbout) { AboutView() }.sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareView(url: shareURL) } } }
    }
}

struct RemoteView: View {
    @EnvironmentObject var model: AppModel; @State private var zoom = 1.0; @State private var touchingDeviceKey = false
    @State private var recording: OfflineRecording = .short
    var body: some View { ScrollView { VStack(spacing: 14) {
        Text(model.connectionState).font(.caption).foregroundStyle(model.isConnected ? .green : .secondary)
        Group {
            if let image = model.displayImage { Image(uiImage: image).resizable().interpolation(.none) }
            else { Canvas { context, size in let sx = size.width/160, sy = size.height/128; for y in 0..<128 { for x in 0..<160 { context.fill(Path(CGRect(x:CGFloat(x)*sx,y:CGFloat(y)*sy,width:sx+0.5,height:sy+0.5)),with:.color(model.pixels[y*160+x])) } } } }
        }.aspectRatio(160.0/128.0,contentMode:.fit).background(.black).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(.gray,lineWidth:5)).scaleEffect(zoom).gesture(MagnificationGesture().onChanged { zoom = min(max($0,1),4) })
        Button(model.remoteActive ? "Vypnout remote control" : "Zapnout remote control") { model.toggleRemote() }.buttonStyle(.borderedProminent).disabled(!model.isConnected)
        if model.isOfflineDemo {
            Picker("Záznam", selection: $recording) {
                ForEach(OfflineRecording.allCases) { item in Text(item.title).tag(item) }
            }
            HStack {
                Button("Přehrát záznam") { model.playOffline(recording) }.disabled(model.replayPlaying)
                if model.replayPlaying { Button("Zastavit") { model.cancelReplay() } }
            }.buttonStyle(.bordered)
            if model.replayTotal > 0 {
                ProgressView(value: Double(model.replayProgress), total: Double(model.replayTotal))
                Text("\(model.replayProgress) / \(model.replayTotal) rámců").font(.caption)
            }
        }
        Label("Tlačítko přístroje", systemImage: "power")
            .frame(maxWidth: .infinity).padding()
            .background(touchingDeviceKey ? Color.orange : Color.blue)
            .foregroundColor(.white).cornerRadius(12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !touchingDeviceKey { touchingDeviceKey = true; model.pressDeviceKey() }
                }
                .onEnded { _ in touchingDeviceKey = false; model.releaseDeviceKey() })
            .disabled(!model.isConnected)
            .accessibilityLabel("Stisknout tlačítko přístroje")
        Button("Vyžádat překreslení") { model.sendCM(WireMessage.redraw, target: 2) }
            .disabled(!model.isConnected)
        Text(model.status).font(.footnote).foregroundStyle(.secondary)
    }.padding() }.onDisappear { touchingDeviceKey = false; model.releaseDeviceKey() } }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { Form { Section("Přístroj") { HStack { Text("Firmware"); Spacer(); Text(model.firmware).foregroundColor(.secondary) }; HStack { Text("Sériové číslo"); Spacer(); Text(model.serial).foregroundColor(.secondary) }; Picker("Režim",selection:$model.parameters.mode) { Text("Wide Range").tag(0); Text("Advanced").tag(1); Text("TATP").tag(2) }; Toggle("Wi‑Fi flag",isOn:$model.parameters.wifi) }
        threshold("Wide Range",zero:$model.parameters.wideZero,alarm:$model.parameters.wideAlarm); threshold("Advanced",zero:$model.parameters.advancedZero,alarm:$model.parameters.advancedAlarm); threshold("TATP",zero:$model.parameters.tatpZero,alarm:$model.parameters.tatpAlarm)
        Section("Čas a zvuk") { value("Time to OFF",$model.parameters.offTime); value("Sampling Period",$model.parameters.sampling); value("Beep Volume",$model.parameters.beep); value("Alarm Volume",$model.parameters.alarm); value("IR Sampling Power",$model.parameters.irPower) }
        Section { Button("Načíst z přístroje") { model.refreshSettings() }; Button("Uložit do přístroje") { model.saveSettings() }.disabled(!model.isConnected); Button("Obnovit tovární nastavení",role:.destructive) { model.restoreDefaults() }.disabled(!model.isConnected) }
    } }
    private func threshold(_ title:String,zero:Binding<Double>,alarm:Binding<Double>)->some View { Section(title) { value("Zero threshold",zero); value("Alarm threshold",alarm) } }
    private func value(_ title:String,_ binding:Binding<Double>)->some View { HStack { Text(title); Spacer(); TextField(title,value:binding,format:.number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(width:110) } }
}

struct DataView: View {
    @EnvironmentObject var model: AppModel; @Binding var shareURL: URL?; @State private var confirmErase=false
    var body: some View { VStack { HStack { Button("Načíst") { model.refreshData() }; Button("Export TSV") { shareURL=model.exportTSV() }.disabled(model.records.isEmpty); Button("Smazat",role:.destructive) { confirmErase=true }.disabled(!model.isConnected) }.buttonStyle(.bordered).padding(.top)
        List(model.records) { r in HStack { Text("\(r.index)").frame(width:35,alignment:.leading); VStack(alignment:.leading) { Text(r.timestamp,style:.date); Text(r.timestamp,style:.time).font(.caption) }; Spacer(); Text(r.value,format:.number.precision(.fractionLength(3))); if r.alarm { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.red) } } }
    }.confirmationDialog("Opravdu smazat záznamník přístroje?",isPresented:$confirmErase,titleVisibility:.visible) { Button("Smazat",role:.destructive) { model.eraseData() } } }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    var body: some View { NavigationView { Form { Section("Wi‑Fi / TCP") { TextField("IP adresa",text:$model.host).autocapitalization(.none).keyboardType(.numbersAndPunctuation); TextField("Port",value:$model.port,format:.number).keyboardType(.numberPad); Button("Připojit") { model.connect(); dismiss() } }
        Section("Internet bridge") { TextField("Server",text:$model.bridgeHost).autocapitalization(.none); TextField("Port",value:$model.bridgePort,format:.number); TextField("32znakové ID přístroje",text:$model.deviceID); Button("Připojit k bridge") { model.connect(bridge:true); dismiss() }.disabled(model.deviceID.count != 32) }
        Section("Remote Control") { Picker("Jazyk",selection:$model.rcLanguage) { ForEach(["English","Japanese","Arabic","Traditional Chinese","Simplified Chinese","German","Polish"],id:\.self) { Text($0) } } }
        Section { Text("USB není v iOS verzi implementováno.").foregroundStyle(.secondary) }
    }.navigationTitle("Připojení").toolbar { Button("Hotovo") { dismiss() } } } }
}

struct ShareView: UIViewControllerRepresentable { let url:URL; func makeUIViewController(context:Context)->UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }; func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){} }

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String { "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))" }
    var body: some View { NavigationView { Form {
        Section { HStack { Image("AppIconPreview").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading) { Text("miniEX mExView").font(.headline); Text("Verze \(version)").foregroundStyle(.secondary) } } }
        Section("Připojení") { Text("Wi‑Fi / TCP, iOS 15+"); Text("Vzdálený displej používá anglické bitmapy miniEX.") }
    }.navigationTitle("O aplikaci").toolbar { Button("Hotovo") { dismiss() } } } }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var shareLog = false
    var body: some View { VStack(spacing: 0) {
        Form {
            Section("Socket") { HStack { Text("Stav"); Spacer(); Text(model.connectionState).foregroundColor(model.isConnected ? .green : .secondary) }; HStack { Text("Aktivní cíl"); Spacer(); Text(model.activeEndpoint).font(.caption.monospaced()) } }
            Section("Počítadla") { HStack { Text("Předáno TCP"); Spacer(); Text("\(model.bytesSent) B") }; HStack { Text("Zařazeno"); Spacer(); Text("\(model.bytesQueued) B") }; HStack { Text("Přijato"); Spacer(); Text("\(model.bytesReceived) B") }; HStack { Text("Pakety / CM"); Spacer(); Text("\(model.packetCount) / \(model.cmMessageCount)") } }
            Section("Soubor protokolu") { Text(model.diagnosticFileURL.lastPathComponent).font(.caption.monospaced()); Button("Sdílet úplný log") { shareLog = true }; Text("Soubory → Na mém iPhonu → miniEX mExView → miniEX-logs").font(.caption).foregroundStyle(.secondary) }
            Section { HStack { Button("Kopírovat log") { UIPasteboard.general.string = model.diagnosticText }; Spacer(); Button("Vymazat", role: .destructive) { model.clearDiagnostics() } } }
        }.frame(height: 420)
        ScrollView { Text(model.diagnosticText.isEmpty ? "Zatím nejsou žádné události." : model.diagnosticText).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(Color.black).foregroundColor(.green)
    }.sheet(isPresented: $shareLog) { ShareView(url: model.diagnosticFileURL) } }
}
