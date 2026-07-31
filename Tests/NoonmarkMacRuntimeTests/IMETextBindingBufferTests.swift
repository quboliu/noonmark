import NoonmarkMacRuntime
import XCTest

final class IMETextBindingBufferTests: XCTestCase {
    func testMarkedTextStaysNativeAndRejectsStaleExternalValue() {
        var buffer = IMETextBindingBuffer(
            initialText: "原始"
        )

        XCTAssertEqual(
            buffer.nativeSnapshotDidChange(
                text: "原始ni",
                isComposing: true
            ),
            .cancel
        )
        XCTAssertEqual(
            buffer.reconcileExternalText("原始"),
            .preserveNative
        )
        XCTAssertEqual(buffer.nativeText, "原始ni")
        XCTAssertTrue(buffer.hasUnpublishedText)
    }

    func testNewCompositionInvalidatesCommittedTextPublication() throws {
        var buffer = IMETextBindingBuffer(
            initialText: ""
        )

        _ = buffer.nativeSnapshotDidChange(
            text: "你好",
            isComposing: true
        )
        let committed = try XCTUnwrap(
            buffer.nativeSnapshotDidChange(
                text: "你好",
                isComposing: false
            ).schedule
        )
        XCTAssertEqual(
            buffer.nativeSnapshotDidChange(
                text: "你好shi",
                isComposing: true
            ),
            .cancel
        )

        XCTAssertNil(
            buffer.takePublication(for: committed)
        )
        XCTAssertEqual(buffer.nativeText, "你好shi")
    }

    func testOnlyLatestIdlePublicationCanPublish() throws {
        var buffer = IMETextBindingBuffer(
            initialText: ""
        )

        let first = try XCTUnwrap(
            buffer.nativeSnapshotDidChange(
                text: "任",
                isComposing: false
            ).schedule
        )
        let latest = try XCTUnwrap(
            buffer.nativeSnapshotDidChange(
                text: "任务",
                isComposing: false
            ).schedule
        )

        XCTAssertNil(buffer.takePublication(for: first))
        XCTAssertEqual(
            buffer.takePublication(for: latest),
            "任务"
        )
        XCTAssertFalse(buffer.hasUnpublishedText)
        XCTAssertEqual(
            buffer.reconcileExternalText("任务"),
            .preserveNative
        )
    }

    func testEndEditingFlushesLatestCommittedTextImmediately() {
        var buffer = IMETextBindingBuffer(
            initialText: "任务"
        )

        _ = buffer.nativeSnapshotDidChange(
            text: "任务标题",
            isComposing: false
        )

        XCTAssertEqual(
            buffer.takeImmediatePublication(),
            "任务标题"
        )
        XCTAssertNil(buffer.takeImmediatePublication())
        XCTAssertFalse(buffer.hasUnpublishedText)
    }

    func testCleanBufferAcceptsARealExternalReplacement() {
        var buffer = IMETextBindingBuffer(
            initialText: "旧值"
        )

        XCTAssertEqual(
            buffer.reconcileExternalText("新值"),
            .applyExternal("新值")
        )
        XCTAssertEqual(buffer.nativeText, "新值")
        XCTAssertFalse(buffer.hasUnpublishedText)
    }
}

private extension IMETextBindingBuffer.SchedulingDirective {
    var schedule: IMETextBindingBuffer.PublicationSchedule? {
        guard case let .schedule(schedule) = self else {
            return nil
        }
        return schedule
    }
}
