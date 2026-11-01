# Changelog

## 0.1.0 — 2026-11-01

First generalized, experimental release of Windows ARM Boot Repair.

- Removes single-computer and single-USB identity restrictions from the original repair utility.
- Adds diagnostic, interactive and automatic modes with explicit target validation.
- Adds configurable firmware policy and distinct files-only results.
- Retains verified EFI backups and transactional UEFI variable backup/readback/rollback.
- Provides source builds, a portable package and optional offline PE integration.
- Includes mock tests and Windows CI. Physical boot testing of this generic release remains pending.
