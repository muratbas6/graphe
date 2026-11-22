# Graphe — Kullanım Kılavuzu

**Graphe**, felsefe, akademi ve yoğun çok dilli metin okumaları için sıfırdan **macOS native (Swift 6 + SwiftUI + AppKit)** olarak geliştirilmiş, **üçüncü parti kütüphane bağımlılığı olmayan**, çevrimdışı PDF okuyucu, OneNote tarzı not defteri, LaTeX PDF dışa aktarıcı ve sözlük çalışma masasıdır.

> **Sistem Gereksinimleri:** macOS 15 (Sequoia) veya üzeri · Swift 6.0+ (Xcode Command Line Tools)

---

## Kaynak Koddan Derleme ve Kurulum

```bash
git clone https://github.com/muratbas6/graphe.git
cd graphe
./Scripts/build_app.sh release
open build/Graphe.app
```

Uygulamalar klasörüne kopyalamak için:

```bash
cp -R build/Graphe.app /Applications/
```

Tüm dahili testleri çalıştırmak için:

```bash
swift run GrapheSelfTest
```

---

## Öne Çıkan Özellikler

### 1. Minimalist Zen Okuma Alanı, 2-Up Kitap Modu, Okuma Cetveli & Temalar
- **3 Okuma Teması:** **Orijinal**, **Sepya** (sıcak parşömen) ve **Gece** (Soft Dark) — tüm pencere, kenar çubukları, not kağıdı, dipnot önizlemesi ve PDF tuvali tek bir göz yormayan renk ailesinde bütünleşir; Retina vektör metin keskinliği bozulmaz.
- **Hover Üst Şerit:** Okurken PDF'in tepesinde hiçbir teknik çubuk dikkatinizi dağıtmaz; fareyi üst kenara getirdiğinizde sayfa numarası, ileri/geri atlama, yer imi (`⌘D`) ve yakınlaştırma kontrolleri belirir.
- **Çift Sayfa Kitap Görünümü (2-Up — `⇧⌘2`):** Uzun okumalarda gerçek bir kitap gibi iki sayfayı yan yana görüntüleyebilirsiniz.
- **Bölünmüş Ekran (Split View):** Aynı PDF'i iki farklı sayfada yan yana açabilir (`⇧⌘\`) veya iki farklı kitabı (ör. orijinal metin + çeviri) yan yana okuyup **Senkron Kaydırma** (`⌥⌘S`) açabilirsiniz.
- **Otomatik Kenar Kırpma (`⇧⌘C`):** Akademik PDF'lerdeki geniş beyaz boşlukları orijinal dosyaya dokunmadan tek tuşla kırpar.
- **Okuma Cetveli (`⇧⌘R`) & Klavye Gezinimi:** Uzun satırlarda göz takibini kolaylaştıran yatay okuma rehberi ve `J` / `K` / `Space` / `Shift+Space` ile akıcı klavye kaydırması.
- **Komut Paleti (`⌘K`):** Sayfa atlama, kitaplar, bağımsız defterler, içindekiler, temalar, Spotify ve tüm komutlara tek kısayolla erişim.

### 2. OneNote Tarzı Defterler (PDF Bağlı & Bağımsız Defterler)
- **PDF Bağlı & PDF'siz Bağımsız Defterler (`⌘N`):** Her PDF'in sağ panelde kendi çok bölümlü defteri vardır. Ayrıca sol paneldeki **Defterler** sekmesinden PDF açmadan da tam ekran tuvalde çalışabileceğiniz bağımsız not defterleri oluşturabilirsiniz.
- **Gerçek 2B Serbest Tuval & Çakışma Önleme:**
  - **Düz / Noktalı / Çizgili / Kareli** tema uyumlu kağıt stilleri.
  - Kağıtta herhangi bir boş yere tek tıklayıp anında yazmaya başlayabilir, kutuları sürükleyip boyutlandırabilirsiniz; kutular otomatik olarak çakışmayacak şekilde yerleşir ve büyüdükçe alttaki kutuları kendiliğinden aşağı iter.
  - `H1/H2/H3`, **Kalın (`⌘B`)**, *İtalik (`⌘I`)*, Altı Çizili (`⌘U`), liste, tıklanabilir **Yapılacak Kutusu (`☐` ↔ `☑`)**, **`⌘V` ile görsel yapıştırma** ve tam **Geri Al / Yinele (`⌘Z` / `⇧⌘Z`)**.
- **İki Yönlü PDF ↔ Defter Bağlantısı:**
  - PDF'te metin seçip vurguladığınızda (`⌥1`–`⌥5`) orijinal PDF'e dokunmadan vurgulanır ve deftere tıklanabilir **`[s. X]`** bağlantılı alıntı kartı eklenir.
  - PDF içindeki mevcut bir vurguya tıkladığınızda da sağdaki defterde doğrudan o vurgunun bağlı olduğu karta zıplar.
- **Özel Yazı Tipi Seçici (`Aa`):** Mac'inize indirdiğiniz fontları (`~/Library/Fonts`) otomatik algılar (*İndirdiklerim* grubu altında) ve seçkin serif/sans/monospace aileleriyle birlikte hem defter tuvaline hem LaTeX PDF çıktısına uygular.

### 3. LaTeX PDF Dışa Aktarım, Ekran Kırpma (Snapshot) & Markdown
- **Akademik LaTeX PDF Dışa Aktarım (`⇧⌘E`):** Defter sayfanızı, bölümünüzü veya tüm defterinizi sisteminizdeki `xelatex` (MacTeX / BasicTeX) ile klasik akademik A4 PDF'e dönüştürür; alıntı kutularını, görselleri, seçtiğiniz yazı tipini ve yan yana koyduğunuz 2B tuval yerleşimini (`minipage`) korur.
- **3x Retina Snapshot / Bölge Kırpma (`⇧⌘X`):** PDF sayfasındaki herhangi bir şekli, formülü veya tabloyu fareyle çerçeveleyerek (Otomatik Kırpma ve sayfa döndürme dahil 1:1 doğrulukla) hem panoya kopyalar hem aktif defterinize görsel olarak ekler.
- **Obsidian Uyumlu Markdown (`.md`) & Akademik Atıf:** YAML frontmatter'lı temiz Markdown dışa aktarımı ve tek tıkla **Chicago (`⇧⌘Y`)**, **APA 7**, **MLA** ve **BibTeX** atıf kopyalama.

### 4. Klasör Yöneticisi (Vault Explorer), Akıllı Metadata & FTS5 Arama
- Sol paneldeki **Kütüphane → Klasörler** bölümünden kitap klasörlerinizi canlı bağlayabilir, sürükle-bırak ile düzenleyebilirsiniz.
- **Akıllı Metadata & Dosya Adı Temizleme:** Başlık, yazar, yıl, yayınevi ve ISBN düzenleme; karmaşık dosya adlarını `Yazar - Başlık (Yıl).pdf` biçimine dönüştürme.
- **SHA-256 Bütünlük Koruması:** PDF'leri taşısanız veya yeniden adlandırsanız bile vurgularınız, yer imleriniz ve defterleriniz kaybolmaz.
- **Global Tam Metin Arama (SQLite FTS5):** Tüm kitapların tam metninde, vurgularınızda ve defterlerinizde milisaniyeler içinde arama.
- **Tek Dosyada Yedekleme (`.graphebackup`):** Tüm veritabanını, defterleri, görselleri ve Kelime Defterini tek bir arşivde yedekleyip geri yükleyebilirsiniz.

### 5. Çevrimdışı Sözlük (StarDict + macOS), Dipnot Önizleme & Vision OCR
- **Sözlük & Çeviri (`⌥ + Tık`):** macOS yerleşik sözlüğü ve Apple'ın cihaz içi çeviri motoruna ek olarak kendi **StarDict** (`.ifo` / `.idx` / `.dict.dz` / `.syn`) sözlüklerinizi **Sözlük → Kitap ikonu** üzerinden ekleyebilirsiniz. *(Açık kaynak repoda gömülü sözlük dosyası bulunmaz.)*
- **Akıllı Dipnot & Sonnot Önizleme:** PDF içi dipnot bağlantıları veya taranmış metinlerdeki dipnot numaralarına tıkladığınızda sayfanızdan kopmadan keskin Retina önizleme açılır.
- **Çevrimdışı Apple Vision OCR (`⌥⌘O`):** Aktif sayfayı OCR yapma, tüm kitabı arka planda FTS5 için tarama veya görünmez metin katmanlı aranabilir PDF dışa aktarma.

### 6. Spotify Mini Oynatıcı (Opsiyonel Web API)
- Sol kenar çubuğu altında kompakt oynatıcı (albüm kapağı, tıklanabilir süre çubuğu, oynatma ve ses kontrolü).
- Opsiyonel olarak kendi ücretsiz [Spotify Developer](https://developer.spotify.com/dashboard) Client ID'nizi (Redirect URI: `http://127.0.0.1:43821/callback`) girerek pencere değiştirmeden çalma listelerinize göz atabilir ve parça arayabilirsiniz.

---

## Temel Klavye Kısayolları

| Kısayol | İşlev |
| :--- | :--- |
| `⌘K` | Komut Paletini Aç |
| `⌘O` / `⌘N` | PDF Aç / Yeni Bağımsız Defter Oluştur |
| `⌘W` / `⌘1`–`⌘9` | Aktif Sekmeyi Kapat / Sekmeler Arası Geçiş |
| `⌘Z` / `⇧⌘Z` | Geri Al / Yinele |
| `⌘F` / `⌘G` / `⇧⌘G` | Belgede Ara / Sonraki / Önceki |
| `J` / `K` / `Space` | Akıcı Aşağı / Yukarı / Sayfa Kaydır |
| `⌘D` | Bu Sayfaya Yer İmi Ekle / Kaldır |
| `⌘[` / `⌘]` | Önceki / Sonraki Konuma Dön |
| `⌥ + Tık` | Kelimeye Anında Sözlükte Bak |
| `⇧⌘H` veya `⌥1`–`⌥5` | Seçili Metni Vurgula ve Deftere Ekle |
| `⇧⌘X` | Snapshot / Bölge Kırpma Aracı |
| `⇧⌘R` | Okuma Cetvelini Aç / Kapat |
| `⇧⌘Y` | Akademik Atıf Kopyala (Chicago) |
| `⇧⌘2` | Çift Sayfa Kitap Görünümü (2-Up) Aç / Kapat |
| `⌘\` / `⇧⌘\` | Yan Yana 2. PDF Aç / Aynı PDF'i Böl |
| `⌥⌘S` | Senkron Kaydırmayı Aç / Kapat |
| `⇧⌘C` | Otomatik Kenar Kırpmayı Aç / Kapat |
| `⌥⌘O` | Aktif Sayfayı Apple Vision OCR Yap |
| `⇧⌘E` | Notları Dışa Aktar (LaTeX PDF / Markdown) |
| `⌥⌘1` / `⌥⌘2` / `⇧⌘F` | Sol Panel / Sağ Panel / Odak Modu |
| `⌘B` / `⌘I` / `⌘U` | Defter Metin Biçimlendirme (Kalın / İtalik / Altı Çizili) |
| `⌘V` / `Esc` | Defter Tuvaline Görsel Yapıştır / Kutu Odağından Çık |

---

## Lisans

Bu proje **GNU General Public License v3.0 (GPL-3.0)** ile lisanslanmıştır. Ayrıntılar için [LICENSE](../LICENSE) dosyasına bakın.
