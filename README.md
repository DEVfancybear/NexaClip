# NexaClip

Ứng dụng Flutter quản lý clipboard cho Windows. Phiên bản đang phát triển hỗ trợ lịch sử văn bản và ảnh PNG cục bộ khi người dùng bật theo dõi, tìm kiếm văn bản, ghim, sao chép lại và xóa lịch sử. Hỗ trợ ảnh và các chức năng khác vẫn đang được hoàn thiện.

## Thiết lập trên Windows

Cài Flutter SDK theo hướng dẫn chính thức: https://docs.flutter.dev/get-started/install/windows/desktop. Cần thêm Visual Studio với workload **Desktop development with C++** để build ứng dụng Windows.

Từ thư mục này, chạy:

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Cần Flutter stable 3.50.0 trở lên. Các bài kiểm thử lifecycle đã chạy với Flutter 3.50.0; Flutter 3.47.9 có thể gặp assertion khi observer bị hủy trong lúc xử lý yêu cầu thoát.

Kiểm thử tích hợp `integration_test/clipboard_windows_test.dart` dùng clipboard hệ thống thật và hiện bị bỏ qua vì không an toàn. **Không bật lại fixture này khi clipboard có thể chứa dữ liệu riêng tư hoặc bị ứng dụng khác thay đổi**: listener native có thể đọc dữ liệu trước khi bộ lọc thử nghiệm kiểm tra. Test dùng cơ sở dữ liệu tạm; bộ lọc văn bản không ngăn việc đọc dữ liệu khác và chưa lọc ảnh. Việc không thấy một mục riêng tư trong cơ sở dữ liệu cũng không chứng minh thông báo của mục đó đã được xử lý.

Các integration test `copy_windows_test.dart` và `copy_image_windows_test.dart` ghi đè clipboard hệ thống nên mặc định bị bỏ qua. Chỉ bật bằng `--dart-define=NEXACLIP_ISOLATED_CLIPBOARD=true` trong môi trường Windows đã xác minh cô lập hoàn toàn clipboard, không chuyển tiếp hoặc đồng bộ clipboard; không chạy trên clipboard cá nhân.

## Quyền riêng tư và giới hạn

- Văn bản và ảnh được lưu cục bộ trong SQLite **không mã hóa** và có thể chứa mật khẩu hoặc dữ liệu nhạy cảm. Theo dõi mặc định tắt khi mở ứng dụng.
- Phiên bản đang phát triển nhận PNG và thử chuyển một số định dạng DIB/DIBV5 sang PNG; đường nhận DIB native chưa được kiểm thử đầu-cuối với clipboard thật. Nếu bộ xử lý DIB đang bận, phương án dự phòng có thể bị bỏ qua và ứng dụng phát cảnh báo. Giới hạn ảnh PNG là 10 MiB, mỗi cạnh tối đa 8192 pixel và tổng tối đa 16 triệu pixel. Khi sao chép lại, PNG được mã hóa lại và có thể vượt 10 MiB dù ảnh đầu vào nằm trong giới hạn; khi đó NexaClip không ghi ảnh vào clipboard.
- Văn bản clipboard vượt 1 MiB UTF-8 bị bỏ qua, không bị cắt cụt; ứng dụng báo cảnh báo và vẫn thử lưu ảnh nếu có.
- Hàng đợi ảnh chờ xử lý có giới hạn tổng 20 MiB. Khi đầy, bản sao có cả ảnh và văn bản sẽ chỉ lưu văn bản; bản sao chỉ có ảnh báo lỗi và không được lưu.
- Khi sao chép ảnh, ứng dụng chuẩn bị dữ liệu trên luồng riêng và từ chối ghi nếu clipboard đã thay đổi trong lúc ảnh được tải hoặc mã hóa. Chỉ một thao tác sao chép ảnh có thể chuẩn bị tại một thời điểm. Khi đóng, ứng dụng có thể phải chờ bộ mã hóa hoàn tất; không có bảo đảm giới hạn thời gian chờ.
- Xóa lịch sử là xóa logic, không đảm bảo xóa an toàn khỏi tệp, bản sao lưu hoặc thiết bị lưu trữ.
- Sao chép lại thay nội dung clipboard hiện tại. Khi đang theo dõi, văn bản giống hệt hoặc ảnh tĩnh có cùng pixel được cập nhật thời gian ở mục hiện có và giữ trạng thái ghim. Ảnh động chỉ được nhận là trùng khi dữ liệu giống hệt; các mục trùng đã tồn tại không tự xóa.
- Khi clipboard bị ứng dụng khác giữ hoặc thay đổi quá nhanh, NexaClip có thể bỏ lỡ một số bản sao. Không có cơ chế nào bảo đảm nhận diện mọi dữ liệu nhạy cảm.
- Khi nhận yêu cầu đóng thông thường, ứng dụng cố dừng theo dõi, chờ các bản ghi đang xử lý và đóng cơ sở dữ liệu; nếu thao tác thất bại, yêu cầu đóng bị hủy để có thể thử lại. Đường đóng khi native đang xử lý ảnh vẫn chưa được kiểm chứng đầu-cuối. Không có bảo đảm này khi tiến trình bị buộc kết thúc, mất điện hoặc hệ điều hành không gửi yêu cầu đóng.
- Lịch sử giữ tối đa 500 mục không ghim mới nhất; mục đã ghim không bị loại bởi giới hạn này. Khi bỏ ghim, mục cũ có thể bị loại ngay. Xóa toàn bộ cũng xóa mục đã ghim.
