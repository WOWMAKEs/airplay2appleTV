import ApplicationServices
import Foundation

enum Command: String {
    case on
    case off
    case toggle
    case status
    case list
    case debug
    case setup
    case help
}

struct Options {
    var command: Command = .help
    var device: String?
    var deviceIndex: Int?
    var verbose = false
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

let usage = """
airplay-tv: control macOS AirPlay / Screen Mirroring to an Apple TV.

USAGE:
  airplay-tv on --device "Living Room Apple TV"
  airplay-tv off --device "Living Room Apple TV"
  airplay-tv toggle --device "Living Room Apple TV"
  airplay-tv toggle --index 1
  airplay-tv status --device "Living Room Apple TV"
  airplay-tv list
  airplay-tv setup

OPTIONS:
  -d, --device NAME   Apple TV name. Also supports AIRPLAY_TV_NAME.
  -i, --index N       Screen Mirroring row number, starting at 1.
  -v, --verbose       Print the underlying automation output.
  -h, --help          Show this help.

NOTES:
  This tool uses macOS Accessibility automation because Apple does not expose a
  stable public CLI/API for selecting an AirPlay display target.
"""

func parseOptions(_ rawArguments: [String]) throws -> Options {
    var options = Options()
    var arguments = Array(rawArguments.dropFirst())

    if arguments.isEmpty {
        return options
    }

    let commandToken = arguments.removeFirst()
    if commandToken == "-h" || commandToken == "--help" {
        options.command = .help
    } else if let command = Command(rawValue: commandToken) {
        options.command = command
    } else {
        throw CLIError.message("Unknown command: \(commandToken)\n\n\(usage)")
    }

    var index = 0
    while index < arguments.count {
        let token = arguments[index]
        switch token {
        case "-d", "--device":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CLIError.message("\(token) requires a device name.")
            }
            options.device = arguments[valueIndex]
            index += 2
        case "-i", "--index":
            let valueIndex = index + 1
            guard valueIndex < arguments.count, let value = Int(arguments[valueIndex]), value > 0 else {
                throw CLIError.message("\(token) requires a positive row number.")
            }
            options.deviceIndex = value
            index += 2
        case "-v", "--verbose":
            options.verbose = true
            index += 1
        case "-h", "--help":
            options.command = .help
            index += 1
        default:
            throw CLIError.message("Unknown option: \(token)\n\n\(usage)")
        }
    }

    if options.device == nil {
        options.device = ProcessInfo.processInfo.environment["AIRPLAY_TV_NAME"]
    }

    return options
}

func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

@discardableResult
func runOSAScript(_ script: String, arguments: [String]) throws -> (code: Int32, output: String, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script] + arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    let error = String(data: errorData, encoding: .utf8) ?? ""

    return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines), error.trimmingCharacters(in: .whitespacesAndNewlines))
}

func discoverBonjourAirPlayDevices(timeout: TimeInterval = 2.0) -> [String] {
    let serviceTypes = ["_airplay._tcp", "_raop._tcp"]
    var names: [String] = []

    for serviceType in serviceTypes {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-B", serviceType, "local."]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            continue
        }

        Thread.sleep(forTimeInterval: timeout)
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            continue
        }

        for line in output.components(separatedBy: .newlines) {
            guard line.contains(" Add "), line.contains(serviceType) else {
                continue
            }

            let pieces = line.components(separatedBy: serviceType)
            guard let rawName = pieces.last else {
                continue
            }

            let cleaned = rawName
                .replacingOccurrences(of: "local.", with: "")
                .replacingOccurrences(of: "local", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty, !names.contains(cleaned) {
                names.append(cleaned)
            }
        }
    }

    return names.sorted()
}

func mergedListOutput(uiOutput: String, bonjourDevices: [String]) -> String {
    var rows: [String] = []

    if !bonjourDevices.isEmpty {
        rows.append("Bonjour AirPlay devices:")
        rows.append(contentsOf: bonjourDevices.map { "- \($0)" })
    }

    if !uiOutput.isEmpty {
        if !rows.isEmpty {
            rows.append("")
        }
        rows.append("Screen Mirroring clickable rows:")
        rows.append(contentsOf: uiOutput.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    if rows.isEmpty {
        return "No AirPlay devices or Screen Mirroring rows found. Run `airplay-tv debug` and send the output so this macOS UI can be matched."
    }

    return rows.joined(separator: "\n")
}

let automationScript = #"""
on run argv
  set targetDevice to item 1 of argv
  set desiredState to item 2 of argv
  set targetIndex to item 3 of argv as integer

  tell application "System Events"
    set controlCenterProcess to my firstProcess({"Control Center", "ControlCenter"})
    if controlCenterProcess is missing value then error "Cannot find the Control Center process."

    if desiredState is "debug" then
      my openScreenMirroring(controlCenterProcess)
      delay 0.5
      set debugText to my debugTree(controlCenterProcess, 0)
      key code 53
      return debugText
    end if

    my openScreenMirroring(controlCenterProcess)
    delay 0.8

    if desiredState is "list" then
      set namesText to my visibleDeviceNames(controlCenterProcess)
      set slotText to my visibleDeviceSlots(controlCenterProcess)
      key code 53
      if namesText is "" then return slotText
      if slotText is "" then return namesText
      return namesText & linefeed & slotText
    end if

    if targetIndex > 0 then
      set deviceElement to my deviceSlotAtIndex(controlCenterProcess, targetIndex)
      if deviceElement is missing value then
        key code 53
        error "Cannot find Screen Mirroring row " & targetIndex & ". Run `airplay-tv list` and use one of the shown indexes."
      end if
    else
      set deviceElement to my firstPressableElement(controlCenterProcess, {targetDevice})
      if deviceElement is missing value then
        set slotCount to my deviceSlotCount(controlCenterProcess)
        key code 53
        if slotCount > 0 then error "Cannot find Apple TV named '" & targetDevice & "' because macOS did not expose row names. Use `airplay-tv toggle --index 1` or another index from `airplay-tv list`."
        error "Cannot find Apple TV named '" & targetDevice & "'. Run `airplay-tv list` while the Apple TV is awake."
      end if
    end if

    set selectedState to my selectedInTree(deviceElement)

    if desiredState is "status" then
      key code 53
      if selectedState then
        return targetDevice & ": on"
      else
        return targetDevice & ": off"
      end if
    end if

    if desiredState is "on" then
      if selectedState then
        key code 53
        return targetDevice & ": already on"
      end if
      my clickElement(deviceElement)
      delay 1.0
      key code 53
      return targetDevice & ": on requested"
    end if

    if desiredState is "off" then
      if not selectedState then
        key code 53
        return targetDevice & ": already off"
      end if
      my clickElement(deviceElement)
      delay 1.0
      key code 53
      return targetDevice & ": off requested"
    end if

    if desiredState is "toggle" then
      my clickElement(deviceElement)
      delay 1.0
      key code 53
      if selectedState then
        return targetDevice & ": off requested"
      else
        return targetDevice & ": on requested"
      end if
    end if

    key code 53
    error "Unknown desired state: " & desiredState
  end tell
end run

on firstProcess(processNames)
  tell application "System Events"
    repeat with processName in processNames
      try
        if exists process (processName as text) then return process (processName as text)
      end try
    end repeat
  end tell
  return missing value
end firstProcess

on openControlCenter(controlCenterProcess)
  tell application "System Events"
    set buttonCandidates to {"Control Center", "控制中心", "Menu Extras", "菜单附加项"}
    repeat with itemRef in menu bar items of menu bar 1 of controlCenterProcess
      if my nameMatches(itemRef, buttonCandidates) then
        my clickElement(itemRef)
        return
      end if
    end repeat

    set allItems to UI elements of menu bar 1 of controlCenterProcess
    if (count of allItems) > 0 then
      my clickElement(item (count of allItems) of allItems)
      return
    end if
  end tell
  error "Cannot open Control Center from the menu bar."
end openControlCenter

on openScreenMirroring(controlCenterProcess)
  tell application "System Events"
    set mirrorTerms to {"Screen Mirroring", "屏幕镜像", "AirPlay", "隔空播放"}

    try
      repeat with itemRef in menu bar items of menu bar 1 of controlCenterProcess
        if my nameMatches(itemRef, mirrorTerms) then
          my clickElement(itemRef)
          return
        end if
      end repeat
    end try

    my openControlCenter(controlCenterProcess)
    delay 0.35

    set mirrorButton to my firstPressableElement(controlCenterProcess, mirrorTerms)
    if mirrorButton is missing value then set mirrorButton to my firstElement(controlCenterProcess, mirrorTerms)
    if mirrorButton is missing value then
      key code 53
      error "Cannot find Screen Mirroring. Make sure the menu bar Screen Mirroring icon is visible, or open Control Center once manually."
    end if

    my clickElement(mirrorButton)
  end tell
end openScreenMirroring

on clickElement(elementRef)
  tell application "System Events"
    try
      perform action "AXPress" of elementRef
      return
    end try
    click elementRef
  end tell
end clickElement

on firstElement(rootElement, terms)
  tell application "System Events"
    if my nameMatches(rootElement, terms) then return rootElement
    try
      repeat with childRef in UI elements of rootElement
        set resultRef to my firstElement(childRef, terms)
        if resultRef is not missing value then return resultRef
      end repeat
    end try
  end tell
  return missing value
end firstElement

on firstPressableElement(rootElement, terms)
  tell application "System Events"
    if my nameMatches(rootElement, terms) and my canPress(rootElement) then return rootElement

    try
      repeat with childRef in UI elements of rootElement
        set resultRef to my firstPressableElement(childRef, terms)
        if resultRef is not missing value then return resultRef
      end repeat
    end try

    try
      repeat with childRef in UI elements of rootElement
        if my nameMatches(childRef, terms) and my canPress(rootElement) then return rootElement
      end repeat
    end try
  end tell
  return missing value
end firstPressableElement

on canPress(elementRef)
  tell application "System Events"
    try
      if actions of elementRef contains "AXPress" then return true
    end try
  end tell
  return false
end canPress

on nameMatches(elementRef, terms)
  set textValue to my elementText(elementRef)
  repeat with termRef in terms
    set termText to termRef as text
    if termText is not "" and textValue contains termText then return true
  end repeat
  return false
end nameMatches

on elementText(elementRef)
  set pieces to {}
  tell application "System Events"
    try
      set end of pieces to (name of elementRef as text)
    end try
    try
      set end of pieces to (description of elementRef as text)
    end try
    try
      set end of pieces to (title of elementRef as text)
    end try
    try
      set end of pieces to (value of elementRef as text)
    end try
  end tell
  set AppleScript's text item delimiters to " "
  set joinedText to pieces as text
  set AppleScript's text item delimiters to ""
  return joinedText
end elementText

on selectedInTree(rootElement)
  tell application "System Events"
    try
      if (value of rootElement as text) is "1" then return true
    end try
    try
      if selected of rootElement is true then return true
    end try
    try
      repeat with childRef in UI elements of rootElement
        if my selectedInTree(childRef) then return true
      end repeat
    end try
  end tell
  return false
end selectedInTree

on visibleDeviceNames(rootElement)
  set foundNames to {}
  my collectDeviceNames(rootElement, foundNames)
  set AppleScript's text item delimiters to linefeed
  set outputText to foundNames as text
  set AppleScript's text item delimiters to ""
  return outputText
end visibleDeviceNames

on visibleDeviceSlots(rootElement)
  set slotCount to my deviceSlotCount(rootElement)
  if slotCount is 0 then return "No Screen Mirroring rows found."

  set slotRows to {}
  repeat with slotIndex from 1 to slotCount
    set end of slotRows to (slotIndex as text) & ": Screen Mirroring row " & (slotIndex as text)
  end repeat

  set AppleScript's text item delimiters to linefeed
  set outputText to slotRows as text
  set AppleScript's text item delimiters to ""
  return outputText
end visibleDeviceSlots

on deviceSlotCount(rootElement)
  set slotRefs to {}
  my collectDeviceSlots(rootElement, slotRefs)
  return count of slotRefs
end deviceSlotCount

on deviceSlotAtIndex(rootElement, targetIndex)
  set slotRefs to {}
  my collectDeviceSlots(rootElement, slotRefs)
  if targetIndex > (count of slotRefs) then return missing value
  return item targetIndex of slotRefs
end deviceSlotAtIndex

on collectDeviceSlots(rootElement, slotRefs)
  tell application "System Events"
    try
      set elementRole to role of rootElement as text
      set elementDescription to description of rootElement as text
      if elementRole is "AXCheckBox" and elementDescription contains "开关按钮" then set end of slotRefs to rootElement
      if elementRole is "AXCheckBox" and elementDescription contains "checkbox" then set end of slotRefs to rootElement
    end try
    try
      repeat with childRef in UI elements of rootElement
        my collectDeviceSlots(childRef, slotRefs)
      end repeat
    end try
  end tell
end collectDeviceSlots

on collectDeviceNames(rootElement, foundNames)
  tell application "System Events"
    try
      set elementName to name of rootElement as text
      set elementRole to role of rootElement as text
      set elementDescription to description of rootElement as text
      if my looksLikeDeviceName(elementName, elementRole, elementDescription) and foundNames does not contain elementName then set end of foundNames to elementName
    end try
    try
      repeat with childRef in UI elements of rootElement
        my collectDeviceNames(childRef, foundNames)
      end repeat
    end try
  end tell
end collectDeviceNames

on looksLikeDeviceName(elementName, elementRole, elementDescription)
  if elementName is "" then return false
  if elementName is "missing value" then return false
  if elementName is "ControlCenter" then return false
  if elementName is "Control Center" then return false
  if elementName is "控制中心" then return false
  if elementName is "Screen Mirroring" then return false
  if elementName is "屏幕镜像" then return false
  if elementName is "AirPlay" then return false
  if elementName is "隔空播放" then return false
  if elementName contains "Display Settings" then return false
  if elementName contains "显示器设置" then return false
  if elementRole contains "button" then return true
  if elementDescription contains "button" then return true
  if elementName contains "Apple TV" then return true
  if elementName contains "TV" then return true
  return false
end looksLikeDeviceName

on debugTree(rootElement, depth)
  set debugRows to {}
  my collectDebug(rootElement, depth, debugRows)
  set AppleScript's text item delimiters to linefeed
  set outputText to debugRows as text
  set AppleScript's text item delimiters to ""
  return outputText
end debugTree

on collectDebug(rootElement, depth, debugRows)
  tell application "System Events"
    set indentText to ""
    repeat depth times
      set indentText to indentText & "  "
    end repeat

    set roleText to ""
    set nameText to ""
    set descriptionText to ""
    set valueText to ""
    try
      set roleText to role of rootElement as text
    end try
    try
      set nameText to name of rootElement as text
    end try
    try
      set descriptionText to description of rootElement as text
    end try
    try
      set valueText to value of rootElement as text
    end try

    set end of debugRows to indentText & "role=" & roleText & " | name=" & nameText & " | desc=" & descriptionText & " | value=" & valueText

    if depth < 8 then
      try
        repeat with childRef in UI elements of rootElement
          my collectDebug(childRef, depth + 1, debugRows)
        end repeat
      end try
    end if
  end tell
end collectDebug
"""#

func requireDevice(for command: Command, device: String?) throws -> String {
    switch command {
    case .on, .off, .toggle, .status:
        if ProcessInfo.processInfo.environment["AIRPLAY_TV_INDEX"] != nil {
            return device ?? ""
        }
        guard let device, !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.message("Missing Apple TV target. Use --device \"Apple TV Name\", --index 1, AIRPLAY_TV_NAME, or AIRPLAY_TV_INDEX.")
        }
        return device
    case .list, .debug:
        return "__list__"
    case .setup, .help:
        return ""
    }
}

func main() -> Int32 {
    do {
        let options = try parseOptions(CommandLine.arguments)

        if options.command == .help {
            print(usage)
            return 0
        }

        if options.command == .setup {
            if accessibilityTrusted(prompt: true) {
                print("Accessibility permission is already granted.")
                return 0
            }

            print("""
            macOS opened the Accessibility permission prompt.
            Enable this terminal app in:
            System Settings > Privacy & Security > Accessibility
            Then run the command again.
            """)
            return 2
        }

        guard accessibilityTrusted(prompt: true) else {
            throw CLIError.message("""
            Accessibility permission is required.
            Run `airplay-tv setup`, grant permission to your terminal app, then retry.
            """)
        }

        let environmentIndex = ProcessInfo.processInfo.environment["AIRPLAY_TV_INDEX"].flatMap(Int.init)
        let useIndexByDefault = options.command == .on || options.command == .off || options.command == .toggle || options.command == .status
        let deviceIndex = options.deviceIndex ?? environmentIndex ?? (useIndexByDefault ? 1 : 0)
        let device = deviceIndex > 0 ? (options.device ?? "") : try requireDevice(for: options.command, device: options.device)
        
        var result: (code: Int32, output: String, error: String) = (0, "", "")
        
        if options.command == .on || options.command == .off {
            let statusResult = try runOSAScript(automationScript, arguments: [device, "status", String(deviceIndex)])
            let isOn = statusResult.output.contains(": on") || statusResult.output.contains("already on")
            
            if options.command == .on {
                if isOn {
                    if let name = options.device, !name.isEmpty {
                        print("\(name): already on")
                    } else {
                        print("already on")
                    }
                } else {
                    result = try runOSAScript(automationScript, arguments: [device, "toggle", String(deviceIndex)])
                }
            } else {
                if !isOn {
                    if let name = options.device, !name.isEmpty {
                        print("\(name): already off")
                    } else {
                        print("already off")
                    }
                } else {
                    result = try runOSAScript(automationScript, arguments: [device, "toggle", String(deviceIndex)])
                }
            }
        } else {
            let scriptMode = options.command == .list ? "list" : options.command.rawValue
            result = try runOSAScript(automationScript, arguments: [device, scriptMode, String(deviceIndex)])
            
            if result.code != 0 && deviceIndex > 0 && options.command != .list && options.command != .debug {
                let fallbackResult = try runOSAScript(automationScript, arguments: [options.device ?? "", scriptMode, "1"])
                if fallbackResult.code == 0 {
                    result = fallbackResult
                }
            }
        }

        if options.verbose, !result.error.isEmpty {
            fputs(result.error + "\n", stderr)
        }

        if options.command == .list {
            let bonjourDevices = discoverBonjourAirPlayDevices()
            print(mergedListOutput(uiOutput: result.output, bonjourDevices: bonjourDevices))
        } else if !result.output.isEmpty {
            print(result.output)
        }

        if result.code != 0 {
            if result.output.isEmpty, !result.error.isEmpty {
                fputs(result.error + "\n", stderr)
            }
            return result.code
        }

        return 0
    } catch {
        fputs("\(error)\n", stderr)
        return 1
    }
}

exit(main())
