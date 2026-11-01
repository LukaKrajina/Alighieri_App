/// 勋章目录（与 Web 版 `lib/badges.ts` 保持一致）。
///
/// 只列**不可重复获得**的里程碑型；没有等级，也没有任何权重。
/// 所有文案都走 i18n 键，避免五种语言里各写一份徽章名 —— 维护五份同义词并不快乐。
class BadgeDef {
  const BadgeDef({
    required this.id,
    required this.titleKey,
    required this.descKey,
    required this.criteriaKey,
  });

  final String id;
  final String titleKey;
  final String descKey;
  final String criteriaKey;
}

const List<BadgeDef> kBadges = [
  BadgeDef(
    id: 'first-work',
    titleKey: 'badge.firstWork.title',
    descKey: 'badge.firstWork.desc',
    criteriaKey: 'badge.firstWork.criteria',
  ),
  BadgeDef(
    id: 'ongoing-year',
    titleKey: 'badge.ongoingYear.title',
    descKey: 'badge.ongoingYear.desc',
    criteriaKey: 'badge.ongoingYear.criteria',
  ),
  BadgeDef(
    id: 'ongoing-three-year',
    titleKey: 'badge.ongoingThreeYear.title',
    descKey: 'badge.ongoingThreeYear.desc',
    criteriaKey: 'badge.ongoingThreeYear.criteria',
  ),
  BadgeDef(
    id: 'reader',
    titleKey: 'badge.reader.title',
    descKey: 'badge.reader.desc',
    criteriaKey: 'badge.reader.criteria',
  ),
  BadgeDef(
    id: 'supported',
    titleKey: 'badge.supported.title',
    descKey: 'badge.supported.desc',
    criteriaKey: 'badge.supported.criteria',
  ),
  BadgeDef(
    id: 'licensed',
    titleKey: 'badge.licensed.title',
    descKey: 'badge.licensed.desc',
    criteriaKey: 'badge.licensed.criteria',
  ),
  BadgeDef(
    id: 'contest',
    titleKey: 'badge.contest.title',
    descKey: 'badge.contest.desc',
    criteriaKey: 'badge.contest.criteria',
  ),
  BadgeDef(
    id: 'translator',
    titleKey: 'badge.translator.title',
    descKey: 'badge.translator.desc',
    criteriaKey: 'badge.translator.criteria',
  ),
  BadgeDef(
    id: 'certificate',
    titleKey: 'badge.certificate.title',
    descKey: 'badge.certificate.desc',
    criteriaKey: 'badge.certificate.criteria',
  ),
  BadgeDef(
    id: 'contributor',
    titleKey: 'badge.contributor.title',
    descKey: 'badge.contributor.desc',
    criteriaKey: 'badge.contributor.criteria',
  ),
  BadgeDef(
    id: 'editor-group',
    titleKey: 'badge.editorGroup.title',
    descKey: 'badge.editorGroup.desc',
    criteriaKey: 'badge.editorGroup.criteria',
  ),
  BadgeDef(
    id: 'contest-winner',
    titleKey: 'badge.contestWinner.title',
    descKey: 'badge.contestWinner.desc',
    criteriaKey: 'badge.contestWinner.criteria',
  ),
  BadgeDef(
    id: 'adapted',
    titleKey: 'badge.adapted.title',
    descKey: 'badge.adapted.desc',
    criteriaKey: 'badge.adapted.criteria',
  ),
];

BadgeDef? badgeDef(String id) {
  for (final b in kBadges) {
    if (b.id == id) return b;
  }
  return null;
}
