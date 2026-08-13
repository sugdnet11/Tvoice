package tj.tvoice.app

import org.junit.Assert.assertEquals
import org.junit.Test

class CallHistoryTrackerTest {
    @Test
    fun recordsConnectedDurationAndPersistsTransitions() {
        val repository = MemoryHistoryRepository()
        val tracker = CallHistoryTracker(repository)

        tracker.load()
        tracker.begin("70001", "Исходящий", "12:00")
        tracker.markConnected(10_000)
        tracker.finish(15_500)

        assertEquals(1, tracker.items.size)
        assertEquals(5L, tracker.items.single().durationSeconds)
        assertEquals(2, repository.saves)
    }

    @Test
    fun ignoresSecondBeginWhileCallIsActive() {
        val repository = MemoryHistoryRepository()
        val tracker = CallHistoryTracker(repository)

        tracker.begin("70001", "Исходящий", "12:00")
        tracker.begin("70002", "Входящий", "12:01")

        assertEquals(listOf("70001"), tracker.items.map(CallHistoryItem::number))
    }

    private class MemoryHistoryRepository : CallHistoryRepository {
        var saves = 0
        override fun load(): List<CallHistoryItem> = emptyList()
        override fun save(items: List<CallHistoryItem>) {
            saves += 1
        }
    }
}
