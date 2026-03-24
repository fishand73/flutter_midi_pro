import Flutter
import AVFoundation
import FluidSynth

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
  private var synths: [Int: OpaquePointer] = [:]
  private var drivers: [Int: OpaquePointer] = [:]
  private var settingsMap: [Int: OpaquePointer] = [:]
  private var soundfonts: [Int: Int32] = [:]
  private var nextSfId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
    let instance = FlutterMidiProPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public override init() {
    super.init()
    configureAudioSession()
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch {
      print("Failed to configure audio session: \(error)")
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadSoundfont":
        let args = call.arguments as! [String: Any]
        let path = args["path"] as! String
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int

        guard let settings = new_fluid_settings() else {
            result(FlutterError(code: "SETTINGS_CREATE_FAILED", message: "Failed to create FluidSynth settings", details: nil))
            return
        }
        fluid_settings_setnum(settings, "synth.gain", 1.0)
        fluid_settings_setint(settings, "audio.period-size", 64)
        fluid_settings_setint(settings, "audio.periods", 4)
        fluid_settings_setint(settings, "audio.realtime-prio", 99)
        fluid_settings_setnum(settings, "synth.sample-rate", 44100.0)
        fluid_settings_setint(settings, "synth.polyphony", 32)

        guard let synth = new_fluid_synth(settings) else {
            delete_fluid_settings(settings)
            result(FlutterError(code: "SYNTH_CREATE_FAILED", message: "Failed to create FluidSynth synth", details: nil))
            return
        }

        let sfId = fluid_synth_sfload(synth, path, 0)
        if sfId == FLUID_FAILED {
            delete_fluid_synth(synth)
            delete_fluid_settings(settings)
            result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: nil))
            return
        }

        for i: Int32 in 0..<16 {
            fluid_synth_program_select(synth, i, sfId, Int32(bank), Int32(program))
        }

        guard let driver = new_fluid_audio_driver(settings, synth) else {
            delete_fluid_synth(synth)
            delete_fluid_settings(settings)
            result(FlutterError(code: "AUDIO_DRIVER_CREATE_FAILED", message: "Failed to create audio driver", details: nil))
            return
        }

        let currentId = nextSfId
        synths[currentId] = synth
        drivers[currentId] = driver
        settingsMap[currentId] = settings
        soundfonts[currentId] = sfId
        nextSfId += 1
        result(currentId)

    case "selectInstrument":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let bank = args["bank"] as! Int
        let program = args["program"] as! Int
        guard let synth = synths[sfId], let fontId = soundfonts[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        fluid_synth_program_select(synth, Int32(channel), fontId, Int32(bank), Int32(program))
        result(nil)

    case "playNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let key = args["key"] as! Int
        let velocity = args["velocity"] as! Int
        let sfId = args["sfId"] as! Int
        guard let synth = synths[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        fluid_synth_noteon(synth, Int32(channel), Int32(key), Int32(velocity))
        result(nil)

    case "stopNote":
        let args = call.arguments as! [String: Any]
        let channel = args["channel"] as! Int
        let key = args["key"] as! Int
        let sfId = args["sfId"] as! Int
        guard let synth = synths[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        fluid_synth_noteoff(synth, Int32(channel), Int32(key))
        result(nil)

    case "stopAllNotes":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        guard let synth = synths[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        for ch: Int32 in 0..<16 {
            fluid_synth_cc(synth, ch, 64, 0)
            fluid_synth_all_sounds_off(synth, ch)
        }
        result(nil)

    case "controlChange":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        let channel = args["channel"] as! Int
        let controller = args["controller"] as! Int
        let value = args["value"] as! Int
        guard let synth = synths[sfId] else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        fluid_synth_cc(synth, Int32(channel), Int32(controller), Int32(value))
        result(nil)

    case "unloadSoundfont":
        let args = call.arguments as! [String: Any]
        let sfId = args["sfId"] as! Int
        guard synths[sfId] != nil else {
            result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
            return
        }
        if let driver = drivers[sfId] {
            delete_fluid_audio_driver(driver)
        }
        if let synth = synths[sfId] {
            delete_fluid_synth(synth)
        }
        if let settings = settingsMap[sfId] {
            delete_fluid_settings(settings)
        }
        synths.removeValue(forKey: sfId)
        drivers.removeValue(forKey: sfId)
        settingsMap.removeValue(forKey: sfId)
        soundfonts.removeValue(forKey: sfId)
        result(nil)

    case "dispose":
        for (id, _) in synths {
            if let driver = drivers[id] {
                delete_fluid_audio_driver(driver)
            }
            if let synth = synths[id] {
                delete_fluid_synth(synth)
            }
            if let settings = settingsMap[id] {
                delete_fluid_settings(settings)
            }
        }
        synths.removeAll()
        drivers.removeAll()
        settingsMap.removeAll()
        soundfonts.removeAll()
        result(nil)

    default:
        result(FlutterMethodNotImplemented)
    }
  }
}
