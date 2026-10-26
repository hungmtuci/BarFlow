# BarFlow for macOS

**BarFlow** là ứng dụng tiện ích siêu nhẹ cho macOS (lấy cảm hứng từ [Bartender](https://www.macbartender.com/)), giúp **chọn lọc các ứng dụng được phép hiển thị trên thanh Menu Bar chính** và gom toàn bộ các ứng dụng còn lại xuống **thanh nổi kính mờ ngay bên dưới Menu Bar** khi bấm phím tắt **`Ctrl + B`**.

<p align="center">
  <img src="docs/images/hero-secondary-bar.png" alt="Thanh phụ BarFlow hiện ngay dưới Menu Bar khi nhấn Ctrl + B" width="960" />
</p>

## 📸 Giao diện Chọn lọc & Quản lý Menu Bar

<p align="center">
  <img src="docs/images/selection-dashboard.png" alt="Bảng điều khiển chọn lọc ứng dụng Menu Bar của BarFlow" width="760" />
</p>

## ✨ Tính năng nổi bật

- **Chọn lọc trực quan khi khởi chạy**: Tự động quét danh sách toàn bộ ứng dụng đang chạy trên Menu Bar (tương thích cả kiến trúc `MenuBarAgent` mới nhất trên **macOS 26 Tahoe / macOS 27** lẫn **macOS 14 Sonoma / 15 Sequoia**).
- **Xem trước 2 vùng theo thời gian thực**: Hiển thị trực quan nhóm biểu tượng giữ lại trên **Menu Bar chính** và nhóm chuyển xuống **Thanh phụ `Ctrl + B`**, tự động sắp xếp các biểu tượng bằng một cú nhấp chuột (**Áp dụng lên Menu Bar**).
- **Thanh phụ nổi ngay dưới Menu Bar (`Ctrl + B`)**:
  - Trượt mượt ngay phía dưới Menu Bar tại màn hình đang đặt con trỏ chuột (hỗ trợ đa màn hình & màn hình tai thỏ MacBook).
  - Không cướp tiêu điểm bàn phím (`NSPanel` non-activating) của ứng dụng bạn đang làm việc.
  - **Click chuột trái** vào biểu tượng để mở menu / popover thật của ứng dụng đó (tự động thu gọn lại ngay sau khi bạn đóng menu); **click chuột phải** để mở menu ngữ cảnh hoặc ghim nhanh lên Menu Bar chính.
- **Tự động ẩn thông minh & Toggle tức thì**:
  - Tự động ẩn sau khoảng thời gian tuỳ chỉnh (`3s`, `5s`, `8s`, `12s`, `20s`, hoặc thủ công), tự động **tạm dừng đếm ngược** khi con trỏ chuột đang rê bên trong thanh phụ.
  - Bấm lại **`Ctrl + B`** 1 lần nữa (hoặc phím `Esc`, hoặc click ra ngoài) để ẩn thanh phụ ngay lập tức.

## ⌨️ Phím tắt & Thao tác nhanh

| Phím tắt / Thao tác | Chức năng |
| :--- | :--- |
| `Ctrl + B` (`⌃B`) | Hiện thanh ứng dụng phụ ngay dưới Menu Bar (bấm lại 1 lần để ẩn ngay) |
| `Esc` | Đóng nhanh thanh ứng dụng phụ đang mở |
| **Click trái** icon `•••` trên Menu Bar | Hiện / Ẩn thanh ứng dụng phụ (tương đương `Ctrl + B`) |
| **Click phải** icon `•••` trên Menu Bar | Mở menu ngữ cảnh nhanh (Chọn lọc ứng dụng, Sắp xếp lại, Thoát) |

---

## 📥 Tải về & Cài đặt nhanh (macOS 14.0+ Universal: Apple Silicon & Intel)

1. Tải bộ cài mới nhất tại trang **[Releases](https://github.com/hungmtuci/BarFlow/releases/latest)**:
   - **`BarFlow-Installer-v1.0.0.dmg`** *(Khuyên dùng)*
   - Hoặc **`BarFlow-v1.0.0-macOS.zip`**
2. Mở file `.dmg`:
   - Kéo `BarFlow.app` thả vào thư mục **`Applications`**, **HOẶC** nhấp chuột phải vào `Cai_Dat_BarFlow.command` → chọn **Open** để tự động cài đặt và gỡ cờ cách ly Gatekeeper.
3. Nếu macOS báo ứng dụng chưa công chứng Apple Developer ID khi mở lần đầu trên máy mới, chạy lệnh sau trong Terminal:
   ```bash
   xattr -cr /Applications/BarFlow.app && open /Applications/BarFlow.app
   ```
4. Cấp quyền **Accessibility (Trợ năng)** cho `BarFlow` trong **System Settings → Privacy & Security → Accessibility** để ứng dụng có thể đọc danh sách biểu tượng trên Menu Bar và kích hoạt thao tác click.

---

## 🛠️ Tự biên dịch từ mã nguồn (Build from Source)

Yêu cầu: macOS 14.0+ và Xcode hoặc Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/hungmtuci/BarFlow.git
cd BarFlow
chmod +x build_barflow.sh
./build_barflow.sh
```

Sau khi chạy xong `./build_barflow.sh`:
- Ứng dụng được tạo tại `./BarFlow.app`
- Bộ cài `.dmg` và `.zip` được xuất ra tại thư mục `./dist/`

## 📄 Giấy phép

Phát hành theo giấy phép [MIT License](LICENSE).
