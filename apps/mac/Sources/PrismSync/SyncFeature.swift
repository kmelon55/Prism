import PrismKit
import SwiftUI

public enum SyncFeature {
  @MainActor public static func make(context: any PrismContext) -> FeatureContribution {
    let model = SyncModel(url: context.paths.file("sync-v1.json"))
    return FeatureContribution(
      settingsPanes: [
        SettingsPane(
          id: "sync", title: "기기 동기화", systemImage: "arrow.triangle.2.circlepath",
          group: .preferences, order: 25,
          keywords: ["sync", "동기화", "기기", "서버", "클립보드", "cloud", "클라우드", "셀프호스팅"]
        ) {
          SyncSettingsView(model: model)
        }
      ], start: { model.start() })
  }
}
struct SyncSettingsView: View {
  @Bindable var model: SyncModel
  @ViewState private var settingUpServer = false

  private var usingServer: Bool { settingUpServer || model.state.enabled }

  var body: some View {
    PrismSettingsPage("기기 동기화") {
      connectionOptions
      if !usingServer {
        PrismSettingsGroup {
          Text("설정과 클립보드를 이 기기에서만 사용해요.")
          if !model.state.deviceID.isEmpty {
            Text("기존 서버 연결 정보는 보관돼 있어요. ‘내 서버 연결’을 선택하면 동기화를 다시 시작해요.")
              .font(.caption).foregroundStyle(.secondary)
            Button("저장된 서버 연결 해제", role: .destructive) {
              Task { await model.revoke(model.state.deviceID) }
            }.disabled(model.busy)
          }
        }
      } else if model.state.deviceID.isEmpty {
        PrismSettingsGroup(Text("내 서버 연결")) {
          Text("직접 운영하는 Prism 서버에 연결해요.").font(.caption).foregroundStyle(.secondary)
          TextField("HTTPS 서버 주소", text: $model.server)
          TextField("기기 이름", text: $model.deviceName)
          SecureField("서버 연결 코드", text: $model.connectionCode)
          SecureField("공유 암호화 키", text: $model.encryptionKey)
          HStack {
            Button("첫 기기용 키 만들기") { model.generateKey() }
            Button("연결하기") { Task { await model.connect() } }.disabled(model.busy)
          }
          Text("다른 기기에서는 첫 기기의 암호화 키를 입력하세요. 키를 잃어버리면 서버 데이터는 복호화할 수 없어요.").font(.caption)
            .foregroundStyle(.secondary)
          if !model.encryptionKey.isEmpty {
            Button("암호화 키 복사") { model.copy(model.encryptionKey) }
          }
        }
      } else {
        PrismSettingsGroup {
          Text(model.state.server).font(.caption).textSelection(.enabled)
          HStack {
            Button("지금 동기화") { Task { await model.sync() } }

          }.disabled(model.busy || !model.state.enabled)
          Text("보통 1분 간격으로 확인해요. 저전력 모드에서는 5분 간격이며, 잠자기 중에는 멈춰요.").font(.caption).foregroundStyle(
            .secondary)
          Button("다른 기기 연결용 암호화 키 복사") {
            model.showKey()
            model.copy(model.encryptionKey)
            model.encryptionKey = ""
          }
        }
        SyncTransferSettings(model: model)
        PrismSettingsGroup(Text("텍스트 공유")) {
          Toggle(
            "새로 복사한 텍스트 자동 전송",
            isOn: Binding(get: { model.state.sendClipboard }, set: { model.setClipboard($0) }))
          Text(
            "자동 전송에는 클립보드 기록이 켜져 있어야 해요. 제외한 앱과 비공개 표시가 있는 텍스트는 보내지 않아요. 최신 텍스트 한 개를 다음 동기화 때 보내며, 종료하면 전송 대기는 사라져요. 서버 목록은 최근 24시간·최대 50개예요."
          ).font(.caption).foregroundStyle(.secondary)
          TextEditor(text: $model.draft).frame(height: 70)
          Button("작성한 텍스트 보내기") { Task { await model.sendDraft() } }.disabled(
            model.busy || !model.state.enabled || model.draft.isEmpty
              || model.draft.utf8.count > 32768)
          ForEach(model.clips, id: \.id) { clip in
            HStack {
              Text(clip.text).lineLimit(2)
              Spacer()
              Button("복사") { model.copy(clip.text) }
            }
          }
        }
        PrismSettingsGroup(Text("연결한 기기")) {
          ForEach(model.devices) { device in
            HStack {
              Text(device.name + (device.id == model.state.deviceID ? " · 이 기기" : ""))
              Spacer()
              Button("연결 해제", role: .destructive) { Task { await model.revoke(device.id) } }
                .disabled(model.busy)
            }
          }
        }
      }
      Text(model.status).font(.caption).textSelection(.enabled)
    }
  }

  private var connectionOptions: some View {
    PrismSettingsGroup(Text("사용 방식")) {
      Button {
        settingUpServer = false
        model.setEnabled(false)
      } label: {
        HStack {
          Image(systemName: usingServer ? "circle" : "checkmark.circle.fill")
          Text("이 기기에서만 사용")
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.busy)
      .accessibilityValue(usingServer ? "선택 안 됨" : "선택됨")

      HStack {
        Image(systemName: "cloud")
        Text("Prism Cloud")
        Spacer()
        Text("준비 중").font(.caption)
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      Text("공식 클라우드 서비스는 준비 중이에요.")
        .font(.caption).foregroundStyle(.secondary)

      Button {
        settingUpServer = true
        if !model.state.deviceID.isEmpty { model.setEnabled(true) }
      } label: {
        HStack {
          Image(systemName: usingServer ? "checkmark.circle.fill" : "circle")
          Text("내 서버 연결")
          Spacer()
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.busy)
      .accessibilityValue(usingServer ? "선택됨" : "선택 안 됨")
    }
  }
}
