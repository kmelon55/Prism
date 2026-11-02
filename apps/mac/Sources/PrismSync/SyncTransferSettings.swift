import Foundation
import PrismKit
import SwiftUI

struct SyncTransferSettings: View {
  @Bindable var model: SyncModel
  @ViewState private var confirmPublish = false
  var body: some View {
    PrismSettingsGroup(Text("선택해서 가져오기 · 자동 동기화")) {
      Text("연결만으로 설정을 바꾸지 않아요. 필요한 항목을 선택한 뒤 가져오거나 자동 동기화를 시작하세요.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(model.adapters) { adapter in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Toggle(
              adapter.title,
              isOn: Binding(
                get: { model.selectedTransfers.contains(adapter.id) },
                set: { selected in
                  if selected {
                    model.selectedTransfers.insert(adapter.id)
                  } else {
                    model.selectedTransfers.remove(adapter.id)
                  }
                  model.clearPreview()
                }))
            if adapter.sensitive {
              Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel(
                "암호화된 API 키")
            }
            Spacer()
            if model.transferOptions.automatic.contains(adapter.id) {
              Text("자동 동기화").font(.caption)
              Button("중단") { model.stopAutomatic(adapter.id) }
            }
            if model.transferOptions.published.contains(adapter.id) {
              Text("기기 백업").font(.caption)
              Button("백업 중단") { model.stopPublishing(adapter.id) }
            }
          }
          if let message = model.transferMessages[adapter.id] {
            Text(message).font(.caption).foregroundStyle(.orange)
          }
        }
      }
      Text(
        "API 키는 제공자별로 선택해요. 선택한 키만 암호화해서 저장하고, 새 기기에서는 키체인에 보관해요. 사용자 지정 서버의 키와 접속 주소는 아직 포함하지 않아요."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("선택 항목 기기 백업 켜기") { Task { await model.publishSelected(automatic: false) } }
        Button("이 기기 값으로 자동 동기화 시작") { confirmPublish = true }
      }.disabled(model.selectedTransfers.isEmpty || !model.state.enabled)
      Text("기기 백업은 이 맥의 변경을 서버에 저장해요. 자동 동기화는 공통값을 주고받으며 메모·스니펫 삭제도 반영해요. 중단해도 서버에 저장된 값은 남아요.")
        .font(.caption).foregroundStyle(.secondary)
      Picker(
        "가져올 위치",
        selection: Binding(
          get: { model.transferSource },
          set: {
            model.transferSource = $0
            model.clearPreview()
          })
      ) {
        Text("공통 설정").tag("shared")
        ForEach(model.devices) { device in Text(device.name).tag(device.id) }
      }
      Button("선택 항목 미리보기") { Task { await model.previewSelected() } }
        .disabled(model.selectedTransfers.isEmpty || !model.state.enabled)
      if let preview = model.transferPreview {
        Divider()
        Text("가져올 항목").font(.headline)
        ForEach(model.adapters.filter { model.selectedTransfers.contains($0.id) }) { adapter in
          HStack {
            Text(adapter.title)
            Spacer()
            Text(summary(preview.payloads[adapter.id], adapter: adapter)).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text("선택한 설정과 같은 ID의 메모는 가져온 값으로 바뀌어요. 이 기기에만 있는 메모·스니펫·링크는 유지해요. 선택하지 않은 항목은 바꾸지 않아요.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("한 번만 가져오기") { Task { await model.importPreview(automatic: false) } }
          if preview.source == "shared" {
            Button("가져온 뒤 자동 동기화") { Task { await model.importPreview(automatic: true) } }
          }
          Button("취소") { model.clearPreview() }
        }
      }
    }
    .disabled(model.busy)
    .confirmationDialog(
      "선택한 항목의 공통값을 이 기기 값으로 바꾸고 자동 동기화를 시작할까요?", isPresented: $confirmPublish,
      titleVisibility: .visible
    ) {
      Button("선택한 항목으로 시작") { Task { await model.publishSelected(automatic: true) } }
      Button("취소", role: .cancel) {}
    } message: {
      Text(
        model.adapters.filter { model.selectedTransfers.contains($0.id) }.map(\.title).joined(
          separator: ", "))
    }
  }
  private func summary(_ data: Data?, adapter: SyncTransfer) -> String {
    guard let data else { return "저장된 항목 없음 · 제외" }
    if adapter.sensitive {
      return (try? JSONDecoder().decode(String?.self, from: data)) != nil
        ? "저장된 키 가져오기" : "키 없음 · 이 기기의 키 삭제"
    }
    if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
      return "\(array.count)개"
    }
    if let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
      return "\(values.count)개 단축키"
    }
    return String(decoding: data, as: UTF8.self).prefix(80).description
  }
}
