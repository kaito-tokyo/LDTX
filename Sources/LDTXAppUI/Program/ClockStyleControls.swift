import SwiftUI
import LDTXProgram

struct ClockStyleControls: View {
  @Binding var component: ClockComponent

  var body: some View {
    Group {
      Picker("Time Format", selection: $component.uses24HourTime) {
        Text("24-hour").tag(true)
        Text("AM/PM").tag(false)
      }
      Toggle("Show Seconds", isOn: $component.showsSeconds)
      Toggle("Show Date", isOn: $component.showsDate)
      Toggle("Use System Time Zone", isOn: $component.usesSystemTimeZone)
      ProgramColorPicker("Text Color", red: $component.foregroundRed,
        green: $component.foregroundGreen, blue: $component.foregroundBlue,
        alpha: $component.foregroundAlpha)
    }
  }
}
