import Foundation
import Testing
import PrismKit
@testable import PrismSync

private actor CollectionTransport: SyncTransport {
    var records: [String:SyncRecord] = [:]
    func put(_ path: String, record: SyncRecord) { records[path] = record }
    func request<T: Decodable & Sendable>(_ path: String,server:String,token:String,method:String,body:[String:String]?,raw:Data?) async throws -> T {
        let object: [String:Any]
        if path.hasPrefix("collections/") {
            if method == "POST" {
                let input = try JSONSerialization.jsonObject(with:raw!) as! [String:Any]
                let revision = input["revision"] as! Int
                guard (records[path]?.revision ?? 0) == revision else { throw TransferError("conflict") }
                let key = String(path.dropFirst("collections/".count).split(separator:"?")[0])
                records[path] = SyncRecord(key:key,revision:revision+1,ciphertext:input["ciphertext"] as! String)
                object = ["revision":revision+1]
            } else if let record = records[path] {
                object = ["record":["key":record.key,"revision":record.revision,"ciphertext":record.ciphertext]]
            } else { object = ["record":NSNull()] }
        } else if path == "clips" { object = ["clips":[]] }
        else { object = ["devices":[]] }
        return try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object))
    }
}
@MainActor private final class TransferBox { var value = "local"; var reads = 0 }
@Suite(.serialized) @MainActor
struct CollectionTests {
    private func setup() -> (SyncModel,CollectionTransport,TransferBox,URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        let transport = CollectionTransport()
        let model = SyncModel(url:directory.appending(path:"sync.json"),client:transport)
        model.state.enabled = true; model.state.owner = "test"; model.state.deviceID = UUID().uuidString.lowercased()
        model.state.server = "https://example.test"
        model.secrets = SyncSecrets(token:"test",key:SyncCrypto.generateKey())
        let box = TransferBox()
        SyncTransfers.register(SyncTransfer(id:"notes",title:"메모",read:{ box.reads += 1; return Data(box.value.utf8) },validate:{ _ in },apply:{ data,_ in box.value = String(decoding:data,as:UTF8.self) }))
        return (model,transport,box,directory)
    }
    private func remote(_ model:SyncModel,_ text:String,revision:Int=1) throws -> SyncRecord {
        SyncRecord(key:"notes",revision:revision,ciphertext:try SyncCrypto.seal(Data(text.utf8).base64EncodedString(),key:model.secrets!.key,context:model.context("shared","notes")))
    }
    @Test func connectionDoesNotReadOrApplyUnselectedFeatures() async throws {
        let (model,transport,box,dir)=setup(); defer {try? FileManager.default.removeItem(at:dir)}
        await transport.put("collections/notes?source=shared",record:try remote(model,"remote"))
        await model.sync()
        #expect(box.reads == 0); #expect(box.value == "local"); #expect(model.transferOptions.automatic.isEmpty)
    }
    @Test func previewRejectsLocalChangesAndOneTimeImportDoesNotJoinSync() async throws {
        let (model,transport,box,dir)=setup(); defer {try? FileManager.default.removeItem(at:dir)}
        model.selectedTransfers = ["notes"]
        await transport.put("collections/notes?source=shared",record:try remote(model,"remote"))
        await model.previewSelected(); box.value = "edited"
        await model.importPreview(automatic:false)
        #expect(box.value == "edited"); #expect(model.transferPreview == nil)
        await model.previewSelected(); await model.importPreview(automatic:false)
        #expect(box.value == "remote"); #expect(model.transferOptions.automatic.isEmpty)
    }
    @Test func autoSyncDetectsConcurrentChangesAndPersistsOnlyHashes() async throws {
        let (model,transport,box,dir)=setup(); defer {try? FileManager.default.removeItem(at:dir)}
        model.selectedTransfers = ["notes"]
        await transport.put("collections/notes?source=shared",record:try remote(model,"private body"))
        await model.previewSelected(); await model.importPreview(automatic:true)
        #expect(box.value == "private body"); #expect(model.transferOptions.automatic == ["notes"])
        let saved = try String(contentsOf:model.transferStateURL,encoding:.utf8)
        #expect(!saved.contains("private body")); #expect(!saved.contains(model.secrets!.key)); #expect(!saved.contains("\"token\""))
        box.value = "local change"
        await transport.put("collections/notes?source=shared",record:try remote(model,"remote change",revision:2))
        await model.sync()
        #expect(box.value == "local change"); #expect(model.transferMessages["notes"] != nil)
        model.stopAutomatic("notes"); let reads = box.reads
        await model.sync(); #expect(box.reads == reads)
    }
    @Test func previewRejectsChangedSourceRevision() async throws {
        let (model,transport,box,dir)=setup(); defer {try? FileManager.default.removeItem(at:dir)}
        model.selectedTransfers = ["notes"]
        await transport.put("collections/notes?source=shared",record:try remote(model,"first"))
        await model.previewSelected()
        await transport.put("collections/notes?source=shared",record:try remote(model,"second",revision:2))
        await model.importPreview(automatic:false)
        #expect(box.value == "local")
    }
}
