# Doğrulama kapsamı

## Geliştirme sohbetlerinde kayda geçmiş kontroller

- macOS'ta örnek videoyu bölme/kırpma ve müzikli MP4 çıktı.
- Dikey kaynağın korunması ve 1:1 sesli çıktı.
- Zaman çizelgesinde tıklama, bölme, taşıma/kırpma ve boşluklu çıktı.
- Sonda kararma çıktısı, tam ekran açma/çıkma ve temel kısayollar.
- Kadrena marka değişikliği sonrası uygulama açılışı ve paket kontrolü.
- iOS simülatör/cihaz derlemeleri; fiziksel iPhone'da kurulum ve açılış.

## Bu depo aktarımının sınırı

Önceki kontroller sohbet kayıtlarıdır, bu aktarımda yeniden yapılmış bütün platform testleri değildir. macOS betiği paket aktarımı için eklenmiştir; yeni derleme sonucu ayrıca raporlanır. iOS çalışma zamanının tüm ekran/format/device kombinasyonları doğrulanmamıştır. Kaynak medya taşınabilirliği ve cihaz kodek farkları ayrıca test edilmelidir.

## 1 Ekim 2026 kaynak aktarımı kontrolü

Mac uygulaması bu depodaki betikle yeniden derlendi. İkili mimarileri: **arm64**. Yerel ad-hoc imza `codesign --verify --deep --strict` ile doğrulandı. Bu oturumda GUI işlevleri ve mobil cihaz testi yeniden yapılmadı.
Kadrena derlemesinde eski AVFoundation API kullanımı, Codable kimlik alanı ve Sendable yakalama uyarıları mevcut; derlemeyi engellemedi.
