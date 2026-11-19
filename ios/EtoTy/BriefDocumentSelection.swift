import Foundation

enum BriefDocumentSelection {
    static func chosen(in archive: [CareDocument], selected: Set<String>) -> [CareDocument] {
        archive.filter { selected.contains($0.id) }
    }

    static func available(in archive: [CareDocument], area: Region?, selected: Set<String>) -> [CareDocument] {
        archive.filter { !selected.contains($0.id) && (area == nil || $0.region == area) }
    }
}
