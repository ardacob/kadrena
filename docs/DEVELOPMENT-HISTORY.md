# Geliştirme geçmişi

Kaynak: “Video düzenleme uygulaması oluştur” sohbeti ve eldeki kaynak/teslim dosyaları. Aşağıdaki kayıtlar geliştirme aşamalarıdır; sonradan üretilmiş Git geçmişi değildir.

1. **İlk talep:** Yerel video/ses ekleme, kolay kesme/bölme ve müzik ekleme. CapCut, Clipchamp, DaVinci Resolve, Premiere ve Final Cut çalışma biçimleri referans alındı. Kullanıcı tarayıcı yerine Mac uygulamasını seçti; Soft UI ve sistem fontu istedi.
2. **Video Atölyesi ilk sürüm:** Yerel dosya içe aktarma, klip sıralama, bölme/kırpma, müzik ve ses düzeyi. Örnek klipte düzenleme ve müzikli MP4 çıktısı kayda geçti.
3. **İkinci aşama:** Dikey videonun 16:9'a zorlanması giderildi. Kaynak ve beş tuval oranı, bağımsız ses düzenleme, zaman kodları, soldurma, koyu tema, kare hızı/kalite ayarları ve JSON proje kaydı eklendi. Dikey 180×320 ve sesli 1080×1080 çıktılar kayda geçti.
4. **Üçüncü aşama:** Sayısal ayarlarla sınırlı kurgu yerine zaman çizelgesinde konum seçme, sürükleme, kenardan kırpma, yakınlaştırma ve imleçte bölme geliştirildi. Boşluklu video dışa aktarma kontrolü kayda geçti.
5. **Dördüncü aşama:** Sonda siyaha kararma, tam ekran önizleme, kare kare gezinme ve daha fazla kısayol eklendi. Kararma çıktı dosyasında kontrol edildi.
6. **Kadrena adı ve logo:** Video Atölyesi, Kadrena olarak adlandırıldı. Mor/turkuaz K logosu simgeye ve başlığa eklendi. Uygulama adı, paket imzası ve ZIP doğrulaması kayda geçti.
7. **iPhone/iPad uyarlaması:** SwiftUI, AVFoundation ve PhotosUI ile dokunmatik zaman çizelgesi; medya kopyalama, proje kaydı, oranlar, ses ve çıktı paylaşımı uyarlandı. Simülatör/cihaz derlemeleri yapıldı.
8. **Fiziksel iPhone:** Kişisel Xcode takımıyla kurulum ve uygulama açılışı doğrulandı. Bu, bütün mobil işlevlerin uçtan uca test edildiği anlamına gelmez.

İlk istekteki her biçime çıktı verme hedefi tamamlanmadı. Depodaki son kaynaklar MP4/MOV/M4V kapsamını korur.
