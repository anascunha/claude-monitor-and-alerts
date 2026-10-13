// Claude Monitor no Mac: a mesma janelinha do Windows (overlay.ps1) em Swift/AppKit.
// Sempre por cima, com as sessões do Claude Code (arquivos do hook em
// ~/.claude-monitor/sessions) e o usage (lido de ~/.claude-monitor/usage.json,
// que a status line do plugin grava; nenhum login é lido, nenhuma API é chamada). O Clawd,
// com a picareta, anda pela borda enquanto algo roda, pula parado em cima quando
// há pergunta/permissão e fica parado em cima quando nada roda.
// Sons e texturas do Minecraft só entram se você mesmo os pôs em ~/.claude-monitor; sem
// eles, sons do Mac e os desenhos daqui.
// Clique numa sessão: abre ela no VS Code. Arrastar: botão esquerdo. Duplo clique:
// traz o VS Code. Botão direito: Clawd (liga/desliga), Opacidade, Volume e Fechar.
// Usage bars and the window's own sound are toggled in the right-click menu (config.json "usage", "som"); the update notice was removed.
// A extensão compila isto (xcrun swiftc -swift-version 5 -O -o ClaudeMonitor
// overlay.swift) e abre; a trava em overlay.lock deixa uma só. Quando o binário
// muda (versão nova), ela fecha (reabra com /monitor-open).
// Teste: ClaudeMonitor --foto arquivo.png desenha, salva o PNG (e, ao lado, um
// .txt com o que viu) e sai. O usage vem de --uso arquivo.json, se
// passar. --pasta troca a ~/.claude-monitor por outra. --clicar id clica na linha
// dessa sessão (o .txt diz o link que abriria). --cena "pedra 2.1" fotografa esse
// instante da cena (pedra ou bug), em segundos.
import Cocoa

let ambiente = ProcessInfo.processInfo.environment
let home = ambiente["HOME"] ?? NSHomeDirectory()
let argumentos = CommandLine.arguments
func argumento(_ nome: String) -> String? {
    if let i = argumentos.firstIndex(of: nome), i + 1 < argumentos.count { return argumentos[i + 1] }
    return nil
}
let arquivoFoto = argumento("--foto")
let pasta = argumento("--pasta") ?? home + "/.claude-monitor"
let dirSessoes = pasta + "/sessions"

try? FileManager.default.createDirectory(atPath: pasta, withIntermediateDirectories: true)

// botão direito: Clawd, opacidade e volume, gravados em config.json (o Windows lê o mesmo).
// Sem o arquivo, tudo como antes do menu existir: Clawd ligado, opaco, volume cheio
let arquivoConfig = pasta + "/config.json"
var config = (opacidade: 1.0, clawd: true, volume: 1.0, usage: true, som: false, subagents: true)
if let dados = FileManager.default.contents(atPath: arquivoConfig),
   let o = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] {
    if let v = (o["opacidade"] as? NSNumber)?.doubleValue { config.opacidade = min(1, max(0.2, v)) }
    if let v = o["clawd"] as? Bool { config.clawd = v }
    if let v = o["usage"] as? Bool { config.usage = v }
    if let v = o["som"] as? Bool { config.som = v }
    if let v = o["subagents"] as? Bool { config.subagents = v }
    if let v = (o["volume"] as? NSNumber)?.doubleValue { config.volume = min(1, max(0, v)) }
}
func salvarConfig() {
    let o: [String: Any] = ["opacidade": config.opacidade, "clawd": config.clawd, "volume": config.volume, "usage": config.usage, "som": config.som, "subagents": config.subagents]
    if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: URL(fileURLWithPath: arquivoConfig)) }
}

if arquivoFoto == nil {
    let trava = open(pasta + "/overlay.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    if trava < 0 || flock(trava, LOCK_EX | LOCK_NB) != 0 { exit(0) }
}

func dataDoArquivo(_ caminho: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: caminho))?[.modificationDate] as? Date
}
let binario = Bundle.main.executablePath ?? argumentos[0]
let versao = dataDoArquivo(binario)

func hex(_ codigo: String) -> NSColor {
    var s = codigo.hasPrefix("#") ? String(codigo.dropFirst()) : codigo
    var alfa: CGFloat = 1
    if s.count == 8 {
        alfa = CGFloat(Int(s.prefix(2), radix: 16) ?? 255) / 255
        s = String(s.dropFirst(2))
    }
    let v = Int(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alfa)
}

// situação da sessão (ver situacao) -> cor da bolinha e texto do tooltip
let estados: [String: (cor: String, rotulo: String)] = [
    "working": ("#22C55E", "working"),
    "finished": ("#EF4444", "finished"),
    "question": ("#699BFB", "asked you a question"),
    "permission": ("#FACC15", "waiting for permission"),
]

// --- sons: "hmm" do aldeão = pergunta/permissão, XP = terminou, subir de nível =
// terminou a última (nada rodando nem esperando). Com mais de um, sorteia.
func sonsDoMinecraft(_ nomes: [String]) -> [String] {
    nomes.map { pasta + "/sounds/" + $0 + ".wav" }.filter { FileManager.default.fileExists(atPath: $0) }
}
var aldeao = sonsDoMinecraft(["aldeao_hmm1", "aldeao_hmm2"])
var xp = sonsDoMinecraft(["xp1", "xp2", "xp3"])
var levelup = sonsDoMinecraft(["levelup"])
// Sons personalizados: pergunta/terminou/tudo (.wav ou .mp3) em ~/.claude-monitor/sons/ trocam os padrões
func somPersonalizado(_ nome: String) -> [String] {
    for ext in ["wav", "mp3"] {
        let f = pasta + "/sounds/" + nome + "." + ext
        if let tipo = (try? FileManager.default.attributesOfItem(atPath: f))?[.type] as? FileAttributeType, tipo == .typeRegular { return [f] }
    }
    return []
}
let custom_pergunta = somPersonalizado("question")
if !custom_pergunta.isEmpty { aldeao = custom_pergunta }
let custom_terminou = somPersonalizado("finished")
if !custom_terminou.isEmpty { xp = custom_terminou }
let custom_tudo = somPersonalizado("all-done")
if !custom_tudo.isEmpty { levelup = custom_tudo }
let nomeDoSom = ["permission": "aldeao", "question": "aldeao", "finished": "xp", "tudo": "levelup"]  // pro .txt do --foto
var tocando: NSSound?  // segura o som até acabar de tocar
func tocar(_ situacao: String) {
    guard config.som else { return }  // os beeps do plugin já avisam; o som da janela é opcional (botão direito > Som da janela)
    guard config.volume > 0 else { return }  // volume no 0 (botão direito): mudo
    // sem Minecraft, sons do Mac
    let (arquivos, doMac) = situacao == "tudo" ? (levelup, "Hero") : situacao == "finished" ? (xp, "Glass") : (aldeao, "Ping")
    var som: NSSound?
    if let arquivo = arquivos.randomElement() { som = NSSound(contentsOfFile: arquivo, byReference: true) }
    if som == nil { som = NSSound(named: NSSound.Name(doMac)) }
    tocando?.stop()
    tocando = som
    som?.volume = Float(config.volume)
    som?.play()
}

// --- sessões (mesma regra da extensão e do overlay.ps1) ---
struct Sessao {
    var id: String
    var nome: String
    var estado: String
    var since: Double
    var updated: Double
    var pid: Int32?
    var transcript: String
    var situacao = ""
    var filhas: [Filha] = []
}

// A subagent running inside a session (child row under the session row)
struct Filha { let tipo: String; let desc: String; let since: Double }

func numero(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func lerSessoes(agora: Double) -> [Sessao] {
    let fm = FileManager.default
    guard let arquivos = try? fm.contentsOfDirectory(atPath: dirSessoes) else { return [] }
    var vistas: [String: Sessao] = [:]
    for arquivo in arquivos where arquivo.hasSuffix(".json") {
        guard let dados = fm.contents(atPath: dirSessoes + "/" + arquivo),
              let d = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else { continue }
        let pid = numero(d["pid"]).flatMap { Int32(exactly: $0) }
        let updated = numero(d["updated"]) ?? 0
        // pid vivo; sem pid, atualizada nas últimas 6h
        if let p = pid, p > 0 {
            if kill(p, 0) != 0 && errno != EPERM { continue }
        } else if agora - updated > 6 * 3600 { continue }
        let id = String(arquivo.dropLast(5))
        let transcript = d["transcript"] as? String ?? ""
        var s = Sessao(id: id, nome: titulo(transcript) ?? (d["name"] as? String ?? "session"),
                       estado: d["state"] as? String ?? "waiting", since: numero(d["since"]) ?? updated,
                       updated: updated, pid: pid, transcript: transcript)
        // subagents: tolerate missing/malformed; entries without a string id are ignored
        if let lista = d["subagents"] as? [Any] {
            for item in lista {
                guard let sub = item as? [String: Any], sub["id"] is String else { continue }
                s.filhas.append(Filha(tipo: sub["type"] as? String ?? "subagent",
                                      desc: sub["desc"] as? String ?? "",
                                      since: numero(sub["since"]) ?? updated))
            }
        }
        let chave = pid.map { "pid:\($0)" } ?? "id:\(id)"
        if let v = vistas[chave], v.updated >= s.updated { continue }
        vistas[chave] = s
    }
    return vistas.values.map { s -> Sessao in
        var s = s
        s.situacao = situacao(s)
        return s
    }.sorted { $0.updated > $1.updated }
}

// Título da aba: o do /rename ("custom-title") ganha do automático ("ai-title").
// O hook só grava o nome quando você manda mensagem, e na 1ª ainda não existe
// Security: only open transcripts that are regular files (no symlinks) whose resolved path is
// under ~/.claude/projects. The path comes from a session file that anything on the machine could write.
let raizTranscripts = URL(fileURLWithPath: home + "/.claude/projects").resolvingSymlinksInPath().path + "/"
func transcriptSeguro(_ caminho: String) -> String? {
    guard !caminho.isEmpty,
          let tipo = (try? FileManager.default.attributesOfItem(atPath: caminho))?[.type] as? FileAttributeType,
          tipo == .typeRegular else { return nil }
    let real = URL(fileURLWithPath: caminho).resolvingSymlinksInPath().path
    return real.hasPrefix(raizTranscripts) ? real : nil
}
// título. Lê só o pedaço novo do transcript.
final class LeituraTitulo { var lido: UInt64 = 0; var custom: String?; var ai: String? }
var titulos: [String: LeituraTitulo] = [:]
let marcaAI = Data("\"type\":\"ai-title\"".utf8)
let marcaCustom = Data("\"type\":\"custom-title\"".utf8)
func titulo(_ original: String) -> String? {
    guard let transcript = transcriptSeguro(original) else { return nil }
    let t = titulos[transcript] ?? LeituraTitulo()
    titulos[transcript] = t
    guard let h = FileHandle(forReadingAtPath: transcript) else { return t.custom ?? t.ai }
    defer { h.closeFile() }
    let tamanho = h.seekToEndOfFile()
    if tamanho < t.lido { t.lido = 0; t.custom = nil; t.ai = nil }
    if tamanho > t.lido {
        h.seek(toFileOffset: t.lido)
        let dados = h.readData(ofLength: Int(tamanho - t.lido))
        if let fim = dados.lastIndex(of: 10) {  // não consome linha pela metade
            let completo = dados[dados.startIndex...fim]
            t.lido += UInt64(completo.count)
            for linha in completo.split(separator: 10) {
                guard linha.range(of: marcaAI) != nil || linha.range(of: marcaCustom) != nil,
                      let o = (try? JSONSerialization.jsonObject(with: Data(linha))) as? [String: Any] else { continue }
                if o["type"] as? String == "custom-title", let v = o["customTitle"] as? String, !v.isEmpty { t.custom = v }
                if o["type"] as? String == "ai-title", let v = o["aiTitle"] as? String, !v.isEmpty { t.ai = v }
            }
        }
    }
    return t.custom ?? t.ai
}

// O que a última mensagem da conversa pede: "caixa" (AskUserQuestion aberto),
// "texto" (resposta terminando em pergunta) ou nada. Lê só o fim do transcript,
// e só quando ele muda de tamanho.
final class LeituraPedido { var tamanho: UInt64 = 0; var resultado: String? }
var pedidos: [String: LeituraPedido] = [:]
func ultimoPedido(_ original: String) -> String? {
    guard let transcript = transcriptSeguro(original), let h = FileHandle(forReadingAtPath: transcript) else { return nil }
    defer { h.closeFile() }
    let tamanho = h.seekToEndOfFile()
    if let c = pedidos[transcript], c.tamanho == tamanho { return c.resultado }
    let n = min(tamanho, 65536)
    h.seek(toFileOffset: tamanho - n)
    var linhas = h.readData(ofLength: Int(n)).split(separator: 10)
    if n < tamanho, !linhas.isEmpty { linhas.removeFirst() }  // leu do meio: a 1ª pode ter vindo pela metade
    var resultado: String?
    for linha in linhas.reversed() {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(linha))) as? [String: Any] else { continue }
        let tipo = o["type"] as? String
        if tipo != "assistant" && tipo != "user" { continue }
        if o["isSidechain"] as? Bool == true { continue }
        if tipo == "assistant", let bloco = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]])?.last {
            if bloco["type"] as? String == "tool_use" {
                if bloco["name"] as? String == "AskUserQuestion" { resultado = "caixa" }
            } else if bloco["type"] as? String == "text", let texto = bloco["text"] as? String {
                // "?" entre aspas ou crases é citação (fala de cliente, exemplo), não pergunta pra você
                let ultima = (texto.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
                    .replacingOccurrences(of: "\"[^\"]*\"|“[^”]*”|`[^`]*`", with: "", options: .regularExpression)
                if ultima.contains("?") { resultado = "texto" }
            }
        }
        break
    }
    let c = LeituraPedido()
    c.tamanho = tamanho
    c.resultado = resultado
    pedidos[transcript] = c
    return resultado
}

// Situação a partir do estado do hook + última mensagem. Trabalhando/permissão só
// viram pergunta com a caixinha (texto com "?" no meio do trabalho não conta).
func situacao(_ s: Sessao) -> String {
    var estado = s.estado
    // depois de aprovar uma permissão nenhum hook dispara até a sessão parar; se o
    // transcript mexeu depois do pedido, ela voltou a trabalhar (regra da extensão)
    if estado == "permission", let m = dataDoArquivo(s.transcript), m.timeIntervalSince1970 > s.since + 2 {
        estado = "working"
    }
    if estado == "question" { return "question" }  // AskUserQuestion box open, set by the hook
    let pedido = ultimoPedido(s.transcript)
    if estado == "working" || estado == "permission" { return pedido == "caixa" ? "question" : estado }
    return pedido != nil ? "question" : "finished"
}

// som quando alguma sessão MUDA de situação pra terminou/pergunta/permissão (uma
// vez por mudança; na abertura não toca). Se vierem juntas, o aldeão ganha do XP.
// Terminou a última (todas terminadas, nada rodando nem esperando): sobe de nível.
var ultimaSituacao: [String: String] = [:]
// teste: o --foto parte da situação anterior em antes.json, pra ver qual som tocaria
if arquivoFoto != nil, let dados = FileManager.default.contents(atPath: pasta + "/antes.json"),
   let antes = (try? JSONSerialization.jsonObject(with: dados)) as? [String: String] {
    ultimaSituacao = antes
}
var somDaVez: String?  // o último som decidido (o --foto grava no .txt em vez de tocar)
func avisar(_ sessoes: [Sessao]) {
    var tocar_: String?
    for s in sessoes {
        if let antes = ultimaSituacao[s.id], antes != s.situacao, estados[s.situacao] != nil, s.situacao != "working",
           tocar_ != "permission", tocar_ != "question" {
            tocar_ = s.situacao
        }
        ultimaSituacao[s.id] = s.situacao
    }
    if tocar_ == "finished", sessoes.allSatisfy({ $0.situacao == "finished" }) { tocar_ = "tudo" }
    guard let t = tocar_ else { return }
    somDaVez = t
    if arquivoFoto == nil { tocar(t) }
}

func tempo(_ minutos: Double) -> String {
    guard minutos.isFinite else { return "" }
    let m = max(0, Int(minutos.rounded(.down)))
    if m < 1 { return "now" }
    if m < 60 { return "\(m)m" }
    if m < 1440 { return "\(m / 60)h" + (m % 60 < 10 ? "0" : "") + "\(m % 60)" }
    return "\(m / 1440)d\((m % 1440) / 60)h"
}

// --- usage: lido de ~/.claude-monitor/usage.json (gravado pela status line do plugin), a cada ~10 s ---
struct Medida { let pct: Double; let renova: Date? }
var uso: [(rotulo: String, medida: Medida)]? = nil
var proximaBusca = Date.distantPast

func medida(_ v: Any?) -> Medida? {
    guard let o = v as? [String: Any], let pct = numero(o["used_percentage"]) else { return nil }
    return Medida(pct: pct, renova: numero(o["resets_at"]).map { Date(timeIntervalSince1970: $0) })
}
func usoDe(_ o: [String: Any]) -> [(rotulo: String, medida: Medida)]? {
    let pares: [(String, Medida?)] = [("5h", medida(o["five_hour"])), ("7d", medida(o["seven_day"]))]
    let medidas = pares.compactMap { par -> (rotulo: String, medida: Medida)? in
        guard let m = par.1 else { return nil }
        return (rotulo: par.0, medida: m)
    }
    return medidas.isEmpty ? nil : medidas
}
// arquivo ausente, ilegível ou com "updated" mais velho que 1 h = indisponível
func lerUsage(_ caminho: String, ignorarIdade: Bool = false) -> [(rotulo: String, medida: Medida)]? {
    guard let d = FileManager.default.contents(atPath: caminho),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    if !ignorarIdade {
        guard let atualizado = numero(o["updated"]), Date().timeIntervalSince1970 - atualizado <= 3600 else { return nil }
    }
    return usoDe(o)
}
func buscarUso() {
    if arquivoFoto != nil {  // teste: o usage vem de --uso arquivo.json
        if uso == nil, let f = argumento("--uso") { uso = lerUsage(f, ignorarIdade: true) }
        return
    }
    guard config.usage else { return }
    if Date() < proximaBusca { return }
    proximaBusca = Date().addingTimeInterval(10)
    uso = lerUsage(pasta + "/usage.json")
}

// clique numa sessão: a extensão recebe o link e abre a aba (ou o terminal) dela,
// como o clique na lista dela. Sem VS Code pra receber: só traz o editor.
var cliqueDaVez: String?  // o --foto grava no .txt em vez de abrir
let livresNaUrl = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")  // os do EscapeDataString do Windows
func abrirSessao(_ id: String) {
    let url = "vscode://local.claude-monitor/sessao?id=" + (id.addingPercentEncoding(withAllowedCharacters: livresNaUrl) ?? id)
    if arquivoFoto != nil { cliqueDaVez = url; return }
    if let u = URL(string: url), NSWorkspace.shared.open(u) { return }
    trazerEditor()
}

// Update notice removed: the window never contacts GitHub and never offers a download.
func versaoNova() -> String? { nil }
func clicar(_ alvo: String) {
    if alvo.hasPrefix("sessao:") { abrirSessao(String(alvo.dropFirst(7))) }
    if alvo.hasPrefix("recolher:") {
        let id = String(alvo.dropFirst(9))
        if cartao.recolhidas.contains(id) { cartao.recolhidas.remove(id) } else { cartao.recolhidas.insert(id) }
        atualizar()  // same path as the other toggles: re-layout and redraw
    }
}

func trazerEditor() {
    for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
    where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", id]
        try? p.run()
        return
    }
}

// --- desenho ---
let L: CGFloat = 320, A: CGFloat = 440  // janela fixa; o resto é transparente e o clique passa
let M: CGFloat = 34                      // espaço em volta do cartão, por onde o Clawd anda
let fonte = NSFont(name: "Inter", size: 12) ?? NSFont.systemFont(ofSize: 12)

func escrever(_ s: String, _ c: NSColor, _ r: NSRect, _ alinhamento: NSTextAlignment = .left, tamanho: CGFloat? = nil) {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    p.alignment = alinhamento
    let f = tamanho.map { NSFont.systemFont(ofSize: $0) } ?? fonte
    let h = ceil(f.ascender - f.descender)
    (s as NSString).draw(in: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2, width: r.width, height: h + 1),
                         withAttributes: [.font: f, .foregroundColor: c, .paragraphStyle: p])
}

final class Raiz: NSView {
    override var isFlipped: Bool { true }
}

// trabalhando: a bolinha verde pulsa, pra quem não distingue verde de vermelho (e pra
// não ler "verde = pronto"). Opacidade 0,65 + 0,35·cos(2π·fase), volta inteira em 1,6 s;
// o --foto fica na fase do --pulso (0 = acesa, 0.5 = o mais apagada).
func opacidadeDoPulso() -> CGFloat {
    let fase = arquivoFoto != nil ? Double(argumento("--pulso") ?? "0") ?? 0
        : Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
    return CGFloat(0.65 + 0.35 * cos(2 * Double.pi * fase))
}

// botão direito: os itens que mexem no config.json (o Fechar fica no Cartao)
final class Preferencias: NSObject {
    @objc func alternarClawd(_ item: NSMenuItem) {
        config.clawd.toggle()
        salvarConfig()
        aplicarConfig()
    }
    @objc func alternarUsage(_ item: NSMenuItem) {
        config.usage.toggle()
        if config.usage { proximaBusca = Date.distantPast } else { uso = nil }
        salvarConfig()
        aplicarConfig()
    }
    @objc func alternarSom(_ item: NSMenuItem) {
        config.som.toggle()
        salvarConfig()
    }
    @objc func alternarSubagents(_ item: NSMenuItem) {
        config.subagents.toggle()
        salvarConfig()
        atualizar()  // rebuilds the child rows (or clears them) and re-lays out the card right away
        aplicarConfig()
    }
    // deletes the session's state file; a live session comes back on its next hook event
    @objc func removerSessao(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        // same rule as the hook: letters, digits, '_' and '-', 1 to 128 chars
        let permitidos = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard id.count >= 1, id.count <= 128,
              id.unicodeScalars.allSatisfy({ permitidos.contains($0) }) else { return }
        try? FileManager.default.removeItem(atPath: dirSessoes + "/" + id + ".json")
        atualizar()
    }
    @objc func mudouOpacidade(_ s: NSSlider) {
        config.opacidade = s.doubleValue.rounded() / 100
        rotular(s)
        salvarConfig()
        aplicarConfig()
    }
    @objc func mudouVolume(_ s: NSSlider) {
        config.volume = s.doubleValue.rounded() / 100
        rotular(s)
        salvarConfig()
    }
    func rotular(_ s: NSSlider) { (s.superview?.viewWithTag(1) as? NSTextField)?.stringValue = "\(Int(s.doubleValue.rounded()))%" }
    // "Opacidade ——o—— 90%": item de menu com um slider dentro
    func itemComSlider(_ nome: String, _ minimo: Double, _ valor: Double, _ acao: Selector) -> NSMenuItem {
        let caixa = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        let rotulo = NSTextField(labelWithString: nome)
        rotulo.font = NSFont.menuFont(ofSize: 0)
        rotulo.frame = NSRect(x: 20, y: 4, width: 72, height: 18)
        let slider = NSSlider(value: valor, minValue: minimo, maxValue: 100, target: self, action: acao)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame = NSRect(x: 92, y: 3, width: 94, height: 20)
        let pct = NSTextField(labelWithString: "\(Int(valor.rounded()))%")
        pct.font = NSFont.menuFont(ofSize: 12)
        pct.textColor = .secondaryLabelColor
        pct.alignment = .right
        pct.tag = 1
        pct.frame = NSRect(x: 186, y: 4, width: 36, height: 18)
        for v in [rotulo, slider, pct] as [NSView] { caixa.addSubview(v) }
        let item = NSMenuItem()
        item.view = caixa
        return item
    }
}
let preferencias = Preferencias()

final class Cartao: NSView {
    var linhas: [(id: String, cor: NSColor, nome: String, tempo: String, rotulo: String, pulsa: Bool)] = []
    var dicas: [NSString] = []  // o tooltip não segura o dono
    var aviso: String?  // saiu versão nova: a linha roxa embaixo
    var yAviso: CGFloat = 0
    var filhas: [String: [(tipo: String, texto: String, tempo: String)]] = [:]  // subagent rows by session id (display only, 17 pt each); texto = desc or type
    var timerRolagem: Timer?  // ~15 fps redraw while a child row scrolls; nil when no row overflows
    let larguraFilha: CGFloat = 144
    let fonteFilha = NSFont.systemFont(ofSize: 11)
    override var isFlipped: Bool { true }

    var recolhidas: Set<String> = []  // session ids whose subagent rows are collapsed (in memory only)
    // chevron slot geometry (card coordinates): 28 pt wide, right before the elapsed-time text
    let slotX: CGFloat = 168, slotL: CGFloat = 28

    // subagent rows actually shown for a session (none when collapsed)
    func filhasVisiveis(_ id: String) -> [(tipo: String, texto: String, tempo: String)] { recolhidas.contains(id) ? [] : (filhas[id] ?? []) }
    func temFilhas(_ id: String) -> Bool { !(filhas[id]?.isEmpty ?? true) }
    func nFilhas(_ i: Int) -> CGFloat { CGFloat(filhasVisiveis(linhas[i].id).count) }
    // top y of session row i (child rows of the sessions above included)
    func yDaLinha(_ i: Int) -> CGFloat {
        var y: CGFloat = 6
        for j in 0..<i { y += 20 + nFilhas(j) * 17 }
        return y
    }

    func larguraDoTexto(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: fonteFilha]).width
    }

    // start/stop the redraw timer: it runs only while a visible child row is wider than its text area
    func ajustarRolagem() {
        let rola = linhas.contains { l in
            filhasVisiveis(l.id).contains { larguraDoTexto($0.texto) > larguraFilha + 1 }
        }
        if rola && timerRolagem == nil {
            timerRolagem = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        } else if !rola, let t = timerRolagem {
            t.invalidate()
            timerRolagem = nil
        }
    }

    // child row text: fits = plain draw; wider = marquee clipped to the text area, offset taken from the
    // clock (not from state) so the 2 s rebuild does not restart it
    func escreverFilha(_ texto: String, _ r: NSRect) {
        let cor = hex("#A6A5C4")
        let w = larguraDoTexto(texto)
        guard w > larguraFilha + 1, let ctx = NSGraphicsContext.current?.cgContext else {
            escrever(texto, cor, r, tamanho: 11)
            return
        }
        let excesso = Double(w - larguraFilha)
        let destino = excesso + 4
        let t = max(1.5, excesso / 25)
        let ciclo = 2 * t + 2.4
        let fase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: ciclo)
        var desloc = 0.0
        if fase < 1.2 {
            desloc = 0
        } else if fase < 1.2 + t {
            desloc = destino * (fase - 1.2) / t
        } else if fase < 2.4 + t {
            desloc = destino
        } else {
            desloc = destino * (1 - (fase - 2.4 - t) / t)
        }
        let h = ceil(fonteFilha.ascender - fonteFilha.descender)
        ctx.saveGState()
        ctx.clip(to: r)
        (texto as NSString).draw(at: NSPoint(x: r.minX - CGFloat(desloc), y: r.minY + (r.height - h) / 2),
                                 withAttributes: [.font: fonteFilha, .foregroundColor: cor])
        ctx.restoreGState()
    }

    // preso no canto de baixo à direita, cresce pra cima
    func arrumar() {
        let n = CGFloat(max(linhas.count, 1))
        let u = CGFloat(max(uso?.count ?? 1, 1))
        let extra = (0..<linhas.count).reduce(CGFloat(0)) { $0 + nFilhas($1) } * 17
        yAviso = 6 + n * 20 + extra + 10 + u * 20 + 10
        let h = yAviso - 10 + (aviso == nil ? 0 : 10 + 20) + 6
        frame = NSRect(x: L - M - 242, y: A - M - h, width: 242, height: h)
        removeAllToolTips()
        dicas = []
        for (i, l) in linhas.enumerated() {
            dicas.append(l.rotulo as NSString)
            if temFilhas(l.id) {
                // the row tooltip is split around the chevron slot so the rects do not overlap
                addToolTip(NSRect(x: 0, y: yDaLinha(i), width: slotX, height: 20), owner: dicas[dicas.count - 1], userData: nil)
                addToolTip(NSRect(x: slotX + slotL, y: yDaLinha(i), width: 242 - slotX - slotL, height: 20), owner: dicas[dicas.count - 1], userData: nil)
                dicas.append((recolhidas.contains(l.id) ? "Show subagents" : "Hide subagents") as NSString)
                addToolTip(NSRect(x: slotX, y: yDaLinha(i), width: slotL, height: 20), owner: dicas[dicas.count - 1], userData: nil)
            } else {
                addToolTip(NSRect(x: 0, y: yDaLinha(i), width: 242, height: 20), owner: dicas[dicas.count - 1], userData: nil)
            }
            for (k, f) in filhasVisiveis(l.id).enumerated() {
                dicas.append("\(f.tipo): \(f.texto)" as NSString)
                addToolTip(NSRect(x: 0, y: yDaLinha(i) + 20 + CGFloat(k) * 17, width: 242, height: 17),
                           owner: dicas[dicas.count - 1], userData: nil)
            }
        }
        if aviso != nil {
            dicas.append("Baixa o zip: extraia e siga o COMO ATUALIZAR.txt")
            addToolTip(NSRect(x: 0, y: yAviso, width: 242, height: 20), owner: dicas[dicas.count - 1], userData: nil)
        }
        ajustarRolagem()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // opacidade do botão direito: o cartão inteiro numa camada só (como o Opacity do
        // Windows); opaco, desenha direto como sempre
        let camada = config.opacidade < 1 ? NSGraphicsContext.current?.cgContext : nil
        camada?.saveGState()
        camada?.setAlpha(CGFloat(config.opacidade))
        camada?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            camada?.endTransparencyLayer()
            camada?.restoreGState()
        }
        hex("#F21C1D2F").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let x: CGFloat = 10
        var y: CGFloat = 6
        if linhas.isEmpty {
            escrever("no open sessions", hex("#A6A5C4"), NSRect(x: x, y: y, width: 222, height: 20))
            y += 20
        }
        for l in linhas {
            (l.pulsa ? l.cor.withAlphaComponent(opacidadeDoPulso()) : l.cor).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 6, width: 8, height: 8)).fill()
            // with the subagents option on, every name loses the chevron slot width so columns stay aligned
            escrever(l.nome, hex("#FFFFFF"), NSRect(x: x + 16, y: y, width: config.subagents ? 170 - slotL : 170, height: 20))
            if temFilhas(l.id) {
                let recolhida = recolhidas.contains(l.id)
                let texto = (recolhida ? "› \(filhas[l.id]?.count ?? 0)" : "›") as NSString
                let atributos: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: hex("#DEDAF4")]
                let tam = texto.size(withAttributes: atributos)
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.translateBy(x: slotX + slotL / 2, y: y + 10)
                    // expanded: rotate 90 degrees (y grows downward here, so the chevron points down)
                    if !recolhida { ctx.rotate(by: CGFloat.pi / 2) }
                    texto.draw(at: NSPoint(x: -tam.width / 2, y: -tam.height / 2), withAttributes: atributos)
                    ctx.restoreGState()
                }
            }
            escrever(l.tempo, l.cor, NSRect(x: x + 186, y: y, width: 36, height: 20), .right)
            y += 20
            for f in filhasVisiveis(l.id) {
                escrever("└", hex("#7C7F9E"), NSRect(x: x + 8, y: y, width: 16, height: 17), tamanho: 11)
                escreverFilha(f.texto, NSRect(x: x + 30, y: y, width: larguraFilha, height: 17))
                escrever(f.tempo, hex("#7C7F9E"), NSRect(x: x + 186, y: y, width: 36, height: 17), .right, tamanho: 11)
                y += 17
            }
        }
        y += 5
        hex("#33FFFFFF").setFill()
        NSRect(x: x, y: y, width: 222, height: 1).fill()
        y += 5
        if let nova = aviso {
            hex("#33FFFFFF").setFill()
            NSRect(x: x, y: yAviso - 5, width: 222, height: 1).fill()
            escrever("↑ version \(nova) available · download", hex("#A78BFA"), NSRect(x: x, y: yAviso, width: 222, height: 20))
        }
        guard let medidas = uso else {
            escrever(config.usage || arquivoFoto != nil ? "usage unavailable" : "usage off (right-click)",
                     hex("#7C7F9E"), NSRect(x: x, y: y, width: 222, height: 20))
            return
        }
        for (rotulo, m) in medidas {
            let c = m.pct >= 95 ? hex("#EF4444") : m.pct >= 80 ? hex("#F59E0B") : hex("#699BFB")
            escrever(rotulo, hex("#A6A5C4"), NSRect(x: x, y: y, width: 18, height: 20))
            let trilho = NSRect(x: x + 18, y: y + 8, width: 118, height: 4)
            hex("#33365A").setFill()
            NSBezierPath(roundedRect: trilho, xRadius: 2, yRadius: 2).fill()
            c.setFill()
            let cheio = 118 * CGFloat(min(max(m.pct, 0), 100)) / 100
            NSBezierPath(roundedRect: NSRect(x: trilho.minX, y: trilho.minY, width: cheio, height: 4), xRadius: 2, yRadius: 2).fill()
            escrever(String(format: "%.0f%%", m.pct), c, NSRect(x: x + 136, y: y, width: 38, height: 20), .right)
            // quanto falta pra renovar
            let falta = m.renova.map { tempo($0.timeIntervalSinceNow / 60) } ?? ""
            escrever(falta, hex("#7C7F9E"), NSRect(x: x + 174, y: y, width: 48, height: 20), .right)
            y += 20
        }
    }

    // a linha nesse ponto (coordenadas do cartão: sessões de 20 a partir de y = 6, o
    // aviso em yAviso): "sessao:<id>" ou "baixar", como o Tag do Windows
    func alvoNoPonto(_ p: NSPoint) -> String? {
        guard bounds.contains(p), p.y >= 6 else { return nil }
        if aviso != nil, p.y >= yAviso, p.y < yAviso + 20 { return "baixar" }
        // child rows are display-only: a click there maps to nothing
        for (i, l) in linhas.enumerated() {
            let topo = yDaLinha(i)
            if p.y >= topo, p.y < topo + 20 {
                if temFilhas(l.id), p.x >= slotX, p.x < slotX + slotL { return "recolher:" + l.id }
                return "sessao:" + l.id
            }
        }
        return nil
    }

    // arrasto na mão (o performDrag deixa o arrasto com o sistema e aí não dá pra
    // saber se foi só um clique): andou menos de 3 pontos = clique
    var inicioMouse = NSPoint.zero, inicioJanela = NSPoint.zero
    var alvoClicado: String?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        alvoClicado = nil
        if event.clickCount == 2 { trazerEditor(); return }
        inicioMouse = NSEvent.mouseLocation
        inicioJanela = window?.frame.origin ?? .zero
        // já na descida: durante o arrasto a lista pode se redesenhar
        alvoClicado = alvoNoPonto(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        var destino = NSPoint(x: inicioJanela.x + m.x - inicioMouse.x, y: inicioJanela.y + m.y - inicioMouse.y)
        // sem a trava do sistema, mantém o cartão dentro da tela, na vertical: a base do cartão
        // não passa da base da tela e o topo dele chega até o topo da tela (altura real do cartão).
        // A Raiz é "flipped" (y cresce pra baixo): a distância da base da janela até a base do
        // cartão é bounds.height - frame.maxY, e até o topo do cartão é bounds.height - frame.minY.
        if let v = (window?.screen ?? NSScreen.main)?.visibleFrame,
           let c = subviews.first(where: { $0 is Cartao }) {
            let baseDoCartao = bounds.height - c.frame.maxY
            let topoDoCartao = bounds.height - c.frame.minY
            destino.y = min(max(destino.y, v.minY - baseDoCartao), v.maxY - topoDoCartao)
        }
        window?.setFrameOrigin(destino)
    }
    override func mouseUp(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if let alvo = alvoClicado, hypot(m.x - inicioMouse.x, m.y - inicioMouse.y) < 3 { clicar(alvo) }
        alvoClicado = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // right-click on a session row: offer to remove it from the monitor (first items)
        let alvoDireito = alvoNoPonto(convert(event.locationInWindow, from: nil))
        var idParaRemover: String?
        if let a = alvoDireito {
            if a.hasPrefix("sessao:") { idParaRemover = String(a.dropFirst(7)) }
            else if a.hasPrefix("recolher:") { idParaRemover = String(a.dropFirst(9)) }
        }
        if let id = idParaRemover {
            let remover = NSMenuItem(title: "Remove session from the monitor", action: #selector(Preferencias.removerSessao(_:)), keyEquivalent: "")
            remover.target = preferencias
            remover.representedObject = id
            menu.addItem(remover)
            menu.addItem(.separator())
        }
        let clawd = NSMenuItem(title: "Show mascot", action: #selector(Preferencias.alternarClawd(_:)), keyEquivalent: "")
        clawd.target = preferencias
        clawd.state = config.clawd ? .on : .off
        menu.addItem(clawd)
        let usageItem = NSMenuItem(title: "Show usage", action: #selector(Preferencias.alternarUsage(_:)), keyEquivalent: "")
        usageItem.target = preferencias
        usageItem.state = config.usage ? .on : .off
        menu.addItem(usageItem)
        let somItem = NSMenuItem(title: "Window sound", action: #selector(Preferencias.alternarSom(_:)), keyEquivalent: "")
        somItem.target = preferencias
        somItem.state = config.som ? .on : .off
        menu.addItem(somItem)
        let subItem = NSMenuItem(title: "Show subagents", action: #selector(Preferencias.alternarSubagents(_:)), keyEquivalent: "")
        subItem.target = preferencias
        subItem.state = config.subagents ? .on : .off
        menu.addItem(subItem)
        menu.addItem(preferencias.itemComSlider("Opacity", 20, config.opacidade * 100, #selector(Preferencias.mudouOpacidade(_:))))
        menu.addItem(preferencias.itemComSlider("Volume", 0, config.volume * 100, #selector(Preferencias.mudouVolume(_:))))
        menu.addItem(.separator())
        let fechar = NSMenuItem(title: "Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        fechar.target = NSApp
        menu.addItem(fechar)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// --- Mascote: o Clawd, do Claude Code (igual ao overlay.ps1) ---
// '#' corpo, 'h' faixa na testa (com as pontas fora do corpo), 'o' olho, 'u' sorriso,
// 'A'/'B' os dois pares de pés, que se alternam.
// Origem (0,0) = entre os pés, então ele "pisa" na trilha e o corpo fica pra fora.
// mao = onde ele segura a ferramenta. O Clawd tem pixel 2x mais alto que largo, como os
// meio-blocos do terminal (senão fica achatado).
struct Mascote {
    let sprite: [String]
    let pw: CGFloat
    let ph: CGFloat
    let mao: CGPoint
    let corpoChars: String
    let olhosChars: String
    let corpoCor: String
    let faixaCor: String
    let olhosCor: String
    let pernaCor: String
}
let clawd = Mascote(
        sprite: [
            "...############...",
            "...##o######o##...",
            ".################.",
            "...############...",
            "....A.B....A.B....",
        ],
        pw: 1.5, ph: 3, mao: CGPoint(x: 12, y: -7.5), corpoChars: "#o", olhosChars: "o",
        corpoCor: "#D77757", faixaCor: "#D77757", olhosCor: "#1A1A1A", pernaCor: "#D77757")

// Sem Minecraft: 16x16 desenhados aqui, com o cabo no mesmo pixel das texturas
// do jogo. d/c/b = diamante (contorno, cor, brilho); k/h = cabo; s/e/l = pedra
// (cor, escuro, claro). O bug é sempre daqui (o Minecraft não tem um que sirva).
let cores16: [(Character, String)] = [("d", "#1B6E73"), ("c", "#4AEDD9"), ("b", "#C9FFF6"), ("k", "#3B2A14"),
                                      ("h", "#8A5A2B"), ("s", "#7D7D7D"), ("e", "#5E5E5E"), ("l", "#A0A0A0")]
let desenhos: [String: [String]] = [
    "picareta": [
        "................",
        "....ddddd.......",
        "...dbbcccdd.....",
        "....dddcccbd....",
        ".......ddcccd...",
        ".........dccd...",
        "........kdcbcd..",
        ".......khkdccd..",
        "......khk..dcd..",
        ".....khk...dcd..",
        "....khk.....dd..",
        "...khk..........",
        "..khk...........",
        "..kk............",
        "................",
        "................",
    ],
    "espada": [
        "................",
        "............ddd.",
        "...........dbcd.",
        "..........dbcd..",
        ".........dbcd...",
        "........dbcd....",
        ".......dbcd.....",
        "......dbcd......",
        "..dd.dbcd.......",
        "..dcdbcd........",
        "...dccd.........",
        "...kdcdd........",
        "..khkddcd.......",
        ".khk...dd.......",
        ".kk.............",
        "................",
    ],
    "diamante": [
        "................",
        "................",
        "....dddddddd....",
        "...dbbcccccbd...",
        "..dbbccccccccd..",
        "..dccccccccccd..",
        "...dcccccccbd...",
        "....dccccccd....",
        ".....dccccd.....",
        "......dccd......",
        ".......dd.......",
        "................",
        "................",
        "................",
        "................",
        "................",
    ],
    "pedra": [
        "ssslssssesssslss",
        "sesssssssslsssse",
        "sssbcssesssssbcs",
        "lsdccdsssssesdcd",
        "ssssdsslssssssds",
        "sesssssssbcsssss",
        "ssslsssesdccdsls",
        "ssssssssssdsssss",
        "sbcsslssssssesss",
        "dccdsssssslssbcs",
        "sdsssesssssssdcc",
        "ssssssssbcssssds",
        "slssssesdccdslss",
        "sssesssssdssssss",
        "ssssslsssssssess",
        "esssssssslssssss",
    ],
]
// de lado, olhando pra esquerda (pro Clawd); p/q = as pernas, que se alternam
let bugLinhas = [
    "a............",
    ".a...vvvvv...",
    "..a.vwwvvvvv.",
    ".aaavwvvxvvvv",
    "aoaavvvvvxvvv",
    ".aaaavvvvvxv.",
    "..pq..pq..pq.",
    ".p..qp..qp..q",
]
let coresBug: [(Character, String)] = [("v", "#65A30D"), ("w", "#A3E635"), ("x", "#365314"), ("a", "#111827"),
                                       ("o", "#F8FAFC"), ("p", "#111827"), ("q", "#111827")]
let coresBugVermelho: [(Character, String)] = [("v", "#EF4444"), ("w", "#FCA5A5"), ("x", "#991B1B"), ("a", "#450A0A"),
                                               ("o", "#FEE2E2"), ("p", "#450A0A"), ("q", "#450A0A")]  // levou o golpe

// retângulos de mesma cor num caminho só: pixels vizinhos sem risco entre eles
func forma(_ linhas: [String], _ largura: CGFloat, _ altura: CGFloat, _ dx: CGFloat, _ dy: CGFloat,
           _ pega: (Character) -> Bool) -> CGPath {
    let caminho = CGMutablePath()
    for (lin, linha) in linhas.enumerated() {
        let cs = Array(linha)
        var col = 0
        while col < cs.count {
            if !pega(cs[col]) { col += 1; continue }
            var fim = col
            while fim + 1 < cs.count && pega(cs[fim + 1]) { fim += 1 }
            caminho.addRect(CGRect(x: (CGFloat(col) + dx) * largura, y: (CGFloat(lin) + dy) * altura,
                                   width: CGFloat(fim - col + 1) * largura, height: altura))
            col = fim + 1
        }
    }
    return caminho
}
// os caminhos do mascote, montados uma vez
struct Figura {
    let m: Mascote
    let corpo: CGPath
    let faixa: CGPath
    let olhos: CGPath
    let pernaA: CGPath
    let pernaB: CGPath
    init(_ m: Mascote) {
        let dx = -CGFloat(m.sprite[0].count / 2)
        let dy = -CGFloat(m.sprite.count)
        self.m = m
        corpo = forma(m.sprite, m.pw, m.ph, dx, dy) { m.corpoChars.contains($0) }
        faixa = forma(m.sprite, m.pw, m.ph, dx, dy) { $0 == "h" }
        olhos = forma(m.sprite, m.pw, m.ph, dx, dy) { m.olhosChars.contains($0) }
        pernaA = forma(m.sprite, m.pw, m.ph, dx, dy) { $0 == "A" }
        pernaB = forma(m.sprite, m.pw, m.ph, dx, dy) { $0 == "B" }
    }
}
let fig = Figura(clawd)
// desenho em 1 px por pixel; quem pinta escala
typealias Desenho = [(CGPath, NSColor)]
func desenho(_ linhas: [String], _ cores: [(Character, String)]) -> Desenho {
    cores.map { par -> (CGPath, NSColor) in (forma(linhas, 1, 1, 0, 0, { $0 == par.0 }), hex(par.1)) }
}
let desenhosProntos = desenhos.mapValues { desenho($0, cores16) }
func bug(_ perna: Character, _ cores: [(Character, String)]) -> Desenho {
    let outra: Character = perna == "p" ? "q" : "p"
    return desenho(bugLinhas.map { String($0.map { $0 == outra ? "." : $0 }) }, cores)
}
let bugs: [String: Desenho] = ["p": bug("p", coresBug), "q": bug("q", coresBug),
                               "p!": bug("p", coresBugVermelho), "q!": bug("q", coresBugVermelho)]
// textura do Minecraft (opcional, se estiver na pasta); senão, o desenho daqui
var texturas: [String: NSImage] = [:]
for nome in desenhos.keys { texturas[nome] = NSImage(contentsOfFile: pasta + "/\(nome).png") }
func pintar(_ ctx: CGContext, _ d: Desenho, _ r: CGRect, _ grade: CGSize) {
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.minY)
    ctx.scaleBy(x: r.width / grade.width, y: r.height / grade.height)
    ctx.setShouldAntialias(false)
    for (caminho, cor) in d {
        ctx.addPath(caminho)
        ctx.setFillColor(cor.cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()
}
func pintar(_ ctx: CGContext, _ nome: String, _ r: CGRect) {
    if let img = texturas[nome] {
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else if let d = desenhosProntos[nome] {
        pintar(ctx, d, r, CGSize(width: 16, height: 16))
    }
}
let cabo = CGPoint(x: 2.75, y: 14.85)  // pixel (2,5; 13,5) da textura, em 1,1 por pixel

// --- Cenas: de vez em quando, andando, ele para e luta (igual ao overlay.ps1) ---
// picareta: aparece uma pedra de diamante na frente, ele bate 3x, ela vira farelo
// e sobe um diamante. espada: chega um bug, 3 espadadas, o bug vira fumaça. A
// ferramenta é sorteada cada vez que ele começa a andar. Tudo no referencial de
// quem anda (x+ = pra frente, y- = pra fora do cartão), em função do tempo, então
// o --foto fotografa qualquer instante (--cena "pedra 2.1").
// em segundos: o alvo chega, leva 3 golpes (o 3º mata) e a cena acaba em "fim"
let roteiros: [String: (chega: CGFloat, golpe: CGFloat, fim: CGFloat)] = ["pedra": (0.3, 0.5, 3.2), "bug": (1.0, 0.45, 2.9)]
let voos: [(CGFloat, CGFloat)] = [(-30, -60), (-12, -80), (10, -75), (28, -55), (-22, -30), (20, -35), (0, -90), (34, -20)]  // px/s
let coresFarelo = ["pedra": ["#7D7D7D", "#4AEDD9", "#A0A0A0", "#5E5E5E"], "bug": ["#E5E7EB", "#9CA3AF"]]
// ângulo da ferramenta num golpe (u de 0 a 1): levanta devagar, desce rápido
func golpe(_ u: CGFloat) -> CGFloat { u < 0.7 ? -40 * u / 0.7 : -40 + 110 * (u - 0.7) / 0.3 }
// no instante t da cena: ângulo da ferramenta, s desde o último golpe e s desde que o alvo morreu
func momento(_ tipo: String, _ t: CGFloat) -> (angulo: CGFloat, acerto: CGFloat, morto: CGFloat) {
    let r = roteiros[tipo]!
    let morre = r.chega + 3 * r.golpe
    let g = (t - r.chega) / r.golpe
    return (g >= 0 && g < 3 ? golpe(g.truncatingRemainder(dividingBy: 1)) : 0,
            g >= 1 && t < morre ? g.truncatingRemainder(dividingBy: 1) * r.golpe : 99, t - morre)
}
// a pedra (brota do chão, treme no golpe) ou o bug (chega andando, recua e fica vermelho no golpe)
func pintarAlvo(_ ctx: CGContext, _ tipo: String, _ t: CGFloat) {
    let (_, acerto, morto) = momento(tipo, t)
    guard morto < 0 else { return }
    let r = roteiros[tipo]!
    if tipo == "pedra" {
        let s = min(1, t / r.chega)
        pintar(ctx, "pedra", CGRect(x: 16 + (acerto < 0.1 ? 1 : 0), y: -12 * s, width: 12, height: 12 * s))
    } else {
        let x = t < r.chega ? 42 - 25 * t / r.chega : 17 + (acerto < 0.15 ? 2 : 0)
        let perna = Int(floor(t / 0.1)) % 2 == 1 ? "q" : "p"
        pintar(ctx, bugs[perna + (acerto < 0.15 ? "!" : "")]!, CGRect(x: x, y: -12.8, width: 13 * 1.6, height: 8 * 1.6),
               CGSize(width: 13, height: 8))
    }
}
// farelos da pedra (caem) ou fumaça do bug (nasce em roda, sobe e cresce), por 0,6 s; e o diamante sobe e some
func pintarRestos(_ ctx: CGContext, _ tipo: String, _ t: CGFloat) {
    let d = momento(tipo, t).morto
    guard d >= 0 else { return }
    if d < 0.6 {
        let cores = coresFarelo[tipo]!
        for (i, v) in voos.enumerated() {
            let q: CGRect
            if tipo == "pedra" {
                q = CGRect(x: 22 + v.0 * d, y: -6 + v.1 * d + 150 * d * d, width: 2, height: 2)
            } else {
                let l = 3 + 5 * d
                q = CGRect(x: 27.4 + v.0 * (0.06 + d * 0.3) - l / 2, y: -6.4 + v.1 * (0.06 + d * 0.2) - 10 * d - l / 2, width: l, height: l)
            }
            ctx.setFillColor(hex(cores[i % cores.count]).withAlphaComponent(1 - d / 0.6).cgColor)
            ctx.fill(q)
        }
    }
    if tipo == "pedra" {
        let s = min(1, d / 0.6)
        ctx.saveGState()
        ctx.setAlpha(d < 1 ? 1 : max(0, 1 - (d - 1) / 0.4))
        pintar(ctx, "diamante", CGRect(x: 16.5, y: -11.5 - 16 * (1 - (1 - s) * (1 - s)) + sin(d * 7) * 0.8, width: 11, height: 11))
        ctx.restoreGState()
    }
}

// Trilha = borda arredondada do cartão, no sentido horário; o Clawd gira junto
// nas curvas. Fora do modo "andando" ele fica parado no meio da borda de cima.
final class Palco: NSView {
    weak var cartao: Cartao?
    var modo = ""
    var fracao: CGFloat = 0  // onde ele está na volta (0-1); sobrevive ao cartão mudar de tamanho
    var antes = ProcessInfo.processInfo.systemUptime
    var ferramenta = "picareta"
    var luta: String?  // "pedra" ou "bug" enquanto luta, parado
    var lutaDesde: TimeInterval = 0
    var proxima: TimeInterval = .infinity
    var instante: CGFloat?  // --foto --cena: o instante fixo da cena
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // "andando" (algo rodando): anda, pula, troca de perna e minera (e às vezes luta).
    // "pulando" (pergunta/permissão): parado em cima do cartão, pulando.
    // "parado" (nada rodando): parado em cima do cartão, com as 4 pernas no chão.
    func mudar(_ novo: String) {
        if novo == modo { return }
        luta = nil  // mudou no meio da luta
        if novo == "andando" {
            if let c = cartao?.frame { fracao = (c.width / 2 - 8) / perimetro(c) }  // sai do meio de cima
            if arquivoFoto == nil {  // a foto fica sempre na picareta
                ferramenta = Bool.random() ? "picareta" : "espada"
                proxima = ProcessInfo.processInfo.systemUptime + .random(in: 20...45)
            }
        }
        modo = novo
        needsDisplay = true
    }
    // --cena "pedra 2.1": aquele instante da cena (só no --foto)
    func fotografar(_ cena: String) {
        let partes = cena.split(separator: " ")
        guard partes.count == 2, let t = Double(partes[1]) else { return }
        luta = String(partes[0])
        ferramenta = luta == "bug" ? "espada" : "picareta"
        instante = CGFloat(t)
    }

    func perimetro(_ c: NSRect) -> CGFloat { 2 * (c.width + c.height) - (8 - 2 * .pi) * 8 }

    // ponto e direção a uma distância d do começo da borda de cima (y pra baixo)
    func naBorda(_ c: NSRect, _ distancia: CGFloat) -> (CGPoint, CGFloat) {
        let r: CGFloat = 8
        let reta = c.width - 2 * r, lado = c.height - 2 * r, curva = CGFloat.pi * r / 2
        let trechos: [CGFloat] = [reta, curva, lado, curva, reta, curva, lado, curva]
        var d = distancia
        var i = 0
        while i < 7 && d > trechos[i] {
            d -= trechos[i]
            i += 1
        }
        switch i {
        case 0: return (CGPoint(x: c.minX + r + d, y: c.minY), 0)
        case 1: return arco(CGPoint(x: c.maxX - r, y: c.minY + r), -.pi / 2, d / r)
        case 2: return (CGPoint(x: c.maxX, y: c.minY + r + d), .pi / 2)
        case 3: return arco(CGPoint(x: c.maxX - r, y: c.maxY - r), 0, d / r)
        case 4: return (CGPoint(x: c.maxX - r - d, y: c.maxY), .pi)
        case 5: return arco(CGPoint(x: c.minX + r, y: c.maxY - r), .pi / 2, d / r)
        case 6: return (CGPoint(x: c.minX, y: c.maxY - r - d), -.pi / 2)
        default: return arco(CGPoint(x: c.minX + r, y: c.minY + r), .pi, d / r)
        }
    }
    func arco(_ centro: CGPoint, _ inicio: CGFloat, _ andou: CGFloat) -> (CGPoint, CGFloat) {
        let a = inicio + andou
        return (CGPoint(x: centro.x + 8 * cos(a), y: centro.y + 8 * sin(a)), a + .pi / 2)
    }

    func tique() {
        let agora = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(agora - antes, 0.1))
        antes = agora
        guard modo != "parado", let c = cartao?.frame, c.width > 0 else { return }
        if modo == "andando" && instante == nil {
            if let tipo = luta {
                if CGFloat(agora - lutaDesde) >= roteiros[tipo]!.fim {  // acabou: volta a andar de onde parou
                    luta = nil
                    proxima = agora + .random(in: 20...45)
                }
            } else if agora >= proxima {
                luta = ferramenta == "espada" ? "bug" : "pedra"
                lutaDesde = agora
            } else {
                fracao += 50 * dt / perimetro(c)  // ~50 px/s
                fracao -= fracao.rounded(.down)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = cartao?.frame, c.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = ProcessInfo.processInfo.systemUptime
        var (ponto, angulo) = (CGPoint(x: c.midX, y: c.minY), CGFloat(0))
        if modo == "andando" { (ponto, angulo) = naBorda(c, fracao * perimetro(c)) }
        ctx.saveGState()
        ctx.translateBy(x: ponto.x, y: ponto.y)
        ctx.rotate(by: angulo)
        // lutando: parado, sem pulo, as 4 pernas no chão e a ferramenta golpeando
        let cena = luta.map { ($0, instante ?? CGFloat(t - lutaDesde)) }
        if let c = cena { pintarAlvo(ctx, c.0, c.1) }  // atrás da ferramenta, que bate por cima
        ctx.saveGState()
        if modo != "parado" && cena == nil {
            // pulinhos: sobe rápido e desacelera no alto; a volta acelera
            let u = t.truncatingRemainder(dividingBy: 0.32) / 0.16
            let p = CGFloat(u <= 1 ? u : 2 - u)
            ctx.translateBy(x: 0, y: -5 * (1 - (1 - p) * (1 - p)))
        }
        ctx.saveGState()
        ctx.setShouldAntialias(false)  // sem costuras entre os pixels
        // andando troca de perna a cada meio pulo; parado ou lutando, as 4 no chão
        let passo = Int(t / 0.16) % 2 == 0
        let anda = modo == "andando" && cena == nil
        let camadas: [(CGPath, NSColor)] = [(fig.corpo, hex(fig.m.corpoCor)), (fig.faixa, hex(fig.m.faixaCor)), (fig.olhos, hex(fig.m.olhosCor))]
        for (caminho, cor) in camadas {
            ctx.addPath(caminho)
            ctx.setFillColor(cor.cgColor)
            ctx.fillPath()
        }
        ctx.setFillColor(hex(fig.m.pernaCor).cgColor)
        if !anda || passo { ctx.addPath(fig.pernaA) }
        if !anda || !passo { ctx.addPath(fig.pernaB) }
        ctx.fillPath()
        ctx.restoreGState()

        // ferramenta na mão direita; andando, balança como quem minera
        ctx.translateBy(x: fig.m.mao.x, y: fig.m.mao.y)
        if let c = cena {
            ctx.rotate(by: momento(c.0, c.1).angulo * .pi / 180)
        } else if anda {
            let u = t.truncatingRemainder(dividingBy: 0.64) / 0.32
            let p = u <= 1 ? u : 2 - u
            ctx.rotate(by: CGFloat(-25 + 40 * sin(p * .pi / 2)) * .pi / 180)
        }
        ctx.translateBy(x: -cabo.x, y: -cabo.y)
        pintar(ctx, ferramenta, CGRect(x: 0, y: 0, width: 17.6, height: 17.6))
        ctx.restoreGState()
        if let c = cena { pintarRestos(ctx, c.0, c.1) }
        ctx.restoreGState()
    }
}

// A janela é alta (A) e o cartão fica no fundo dela. Sem este override, o macOS não deixa o topo
// da janela passar da barra de menus, e o cartão não sobe da metade da tela.
final class JanelaFlutuante: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// --- janela ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // sem ícone no Dock
let janela = JanelaFlutuante(contentRect: NSRect(x: 0, y: 0, width: L, height: A),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
janela.isOpaque = false
janela.backgroundColor = .clear
janela.hasShadow = false
janela.level = .floating
janela.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
janela.hidesOnDeactivate = false
janela.isReleasedWhenClosed = false
janela.allowsToolTipsWhenApplicationIsInactive = true
let raiz = Raiz(frame: NSRect(x: 0, y: 0, width: L, height: A))
let cartao = Cartao(frame: .zero)
let palco = Palco(frame: raiz.bounds)
palco.cartao = cartao
raiz.addSubview(cartao)
raiz.addSubview(palco)
janela.contentView = raiz
// o que o botão direito mudou: Clawd desligado = o palco some; a opacidade o Cartao.draw lê
func aplicarConfig() {
    palco.isHidden = !config.clawd
    cartao.needsDisplay = true
}
aplicarConfig()
// nasce no canto de baixo à direita (a margem M já afasta o cartão da borda)
if let tela = NSScreen.main?.visibleFrame { janela.setFrameOrigin(NSPoint(x: tela.maxX - L, y: tela.minY)) }

// The binary was replaced by a new build (/monitor-open): close and let the user reopen it.
// The window never relaunches itself.
func seAtualizou() {
    guard arquivoFoto == nil, let v = versao, let agora = dataDoArquivo(binario), agora != v else { return }
    exit(0)
}

func atualizar() {
    let agora = Date().timeIntervalSince1970
    let sessoes = lerSessoes(agora: agora)
    avisar(sessoes)
    cartao.linhas = sessoes.map { s -> (id: String, cor: NSColor, nome: String, tempo: String, rotulo: String, pulsa: Bool) in
        let e = estados[s.situacao] ?? (cor: "#A6A5C4", rotulo: s.situacao)
        return (id: s.id, cor: hex(e.cor), nome: s.nome, tempo: tempo((agora - s.since) / 60), rotulo: e.rotulo,
                pulsa: s.situacao == "working")
    }
    buscarUso()
    var filhasPorSessao: [String: [(tipo: String, texto: String, tempo: String)]] = [:]
    for s in sessoes {
        filhasPorSessao[s.id] = s.filhas.map { f -> (tipo: String, texto: String, tempo: String) in
            (tipo: f.tipo, texto: f.desc.isEmpty ? f.tipo : f.desc, tempo: tempo((agora - f.since) / 60))
        }
    }
    cartao.filhas = config.subagents ? filhasPorSessao : [:]  // option off: no child rows, no extra height
    cartao.aviso = versaoNova()
    cartao.arrumar()  // redesenha a cada 2 s pra contagem de "falta" andar entre as buscas
    // pedindo algo (pergunta/permissão) ganha de trabalhando, que ganha de parado.
    // Depois do arrumar: na 1ª vez o cartão ainda tem largura 0 e o Clawd sairia por baixo
    let situacoes = Set(sessoes.map { $0.situacao })
    palco.mudar(situacoes.contains("question") || situacoes.contains("permission") ? "pulando"
                : situacoes.contains("working") ? "andando" : "parado")
    palco.needsDisplay = true
    if let foto = arquivoFoto {
        // --clicar: o meio da linha daquela sessão (ou do aviso, com "baixar"), pelo mesmo caminho do clique de verdade
        if let alvo = argumento("--clicar") {
            let y: CGFloat? = alvo == "baixar" ? cartao.yAviso + 10 : cartao.linhas.firstIndex(where: { $0.id == alvo }).map { cartao.yDaLinha($0) + 10 }
            if let y = y, let achou = cartao.alvoNoPonto(NSPoint(x: cartao.bounds.midX, y: y)) { clicar(achou) }
        }
        let clawd = config.clawd ? palco.modo + (palco.luta.map { " (\($0))" } ?? "") : "desligado"
        let visto = sessoes.map { "sessao: \($0.nome) | hook=\($0.estado) | janelinha=\($0.situacao)" }
            + ["clawd: \(clawd)", "usage: \(uso == nil ? "indisponivel" : "ok")",
               "som: \(somDaVez.flatMap { nomeDoSom[$0] } ?? "nenhum")", "clique: \(cliqueDaVez ?? "nenhum")",
               "atualizacao: \(cartao.aviso ?? "nenhuma")"]
        try? (visto.joined(separator: "\n") + "\n").write(toFile: foto + ".txt", atomically: true, encoding: .utf8)
    }
    seAtualizou()
}

func repetir(_ intervalo: TimeInterval, _ bloco: @escaping () -> Void) {
    let t = Timer(timeInterval: intervalo, repeats: true) { _ in bloco() }
    RunLoop.main.add(t, forMode: .common)  // continua durante arrasto e menu
}

atualizar()
janela.orderFrontRegardless()
repetir(2) { atualizar() }
repetir(1.0 / 30) {
    palco.tique()
    // o pulso da bolinha verde: só a coluna das bolinhas
    if cartao.linhas.contains(where: { $0.pulsa }) { cartao.setNeedsDisplay(NSRect(x: 8, y: 0, width: 12, height: cartao.bounds.height)) }
}

if let foto = arquivoFoto {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        if let cena = argumento("--cena") { palco.fotografar(cena) }
        atualizar()
        if let rep = raiz.bitmapImageRepForCachingDisplay(in: raiz.bounds) {
            raiz.cacheDisplay(in: raiz.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: foto))
            print("foto: \(foto)")
        }
        exit(0)
    }
}
app.run()
