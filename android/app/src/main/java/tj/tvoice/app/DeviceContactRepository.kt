package tj.tvoice.app

import android.content.Context
import android.provider.ContactsContract

data class DeviceContact(val name: String, val phone: String)

/** Read-only boundary around Android's contacts provider. Permission stays owned by the UI. */
class DeviceContactRepository(context: Context) {
    private val resolver = context.applicationContext.contentResolver

    fun load(limit: Int = 100): List<DeviceContact> = runCatching {
        val result = mutableListOf<DeviceContact>()
        val nameColumn = ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
        val phoneColumn = ContactsContract.CommonDataKinds.Phone.NUMBER
        resolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(nameColumn, phoneColumn),
            null,
            null,
            "$nameColumn ASC"
        )?.use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow(nameColumn)
            val phoneIndex = cursor.getColumnIndexOrThrow(phoneColumn)
            while (cursor.moveToNext() && result.size < limit) {
                result += DeviceContact(
                    name = cursor.getString(nameIndex).orEmpty(),
                    phone = cursor.getString(phoneIndex).orEmpty()
                )
            }
        }
        result.distinctBy { it.name to it.phone.filter(Char::isDigit) }
    }.getOrDefault(emptyList())
}
