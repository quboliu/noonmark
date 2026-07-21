extension AppCopy {
    var taskCollectionView: String { language == .chinese ? "视图" : "View" }
    var taskCollectionOrganization: String { language == .chinese ? "组织方式" : "Organization" }
    var taskCollectionFlat: String { language == .chinese ? "不分组" : "Flat" }
    var taskCollectionGrouped: String { language == .chinese ? "按分组" : "Group by category" }
    var taskCollectionSortKey: String { language == .chinese ? "排序依据" : "Sort by" }
    var taskCollectionSortTime: String { language == .chinese ? "时间" : "Time" }
    var taskCollectionSortTitle: String { language == .chinese ? "首字母" : "Title" }
    var taskCollectionDirection: String { language == .chinese ? "排序方向" : "Direction" }
    var taskCollectionAscending: String { language == .chinese ? "升序" : "Ascending" }
    var taskCollectionDescending: String { language == .chinese ? "降序" : "Descending" }
}
