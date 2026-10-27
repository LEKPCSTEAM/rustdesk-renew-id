# Renew RustDesk ID

รีเซ็ต RustDesk ID ของเครื่อง Linux ให้เป็น ID ใหม่ มีไอคอนให้กดในรายการ app

ทดสอบบน Ubuntu 24.04 (GNOME) + RustDesk 1.5.0 (ติดตั้งแบบ .deb)

## ติดตั้ง

```bash
sudo apt install zenity pkexec xclip
git clone https://github.com/LEKPCSTEAM/rustdesk-renew-id.git
cd rustdesk-renew-id
bash install.sh          # เฉพาะ user นี้
sudo bash install.sh     # ทุก user
```

## ใช้งาน

- GUI: ค้น **"Renew RustDesk ID"** ในรายการ app
- Terminal / SSH: `sudo rustdesk-renew-id --cli`

## ถอนการติดตั้ง

```bash
bash uninstall.sh        # หรือ sudo bash uninstall.sh ถ้าติดตั้งแบบทุก user
```

## ทำงานยังไง

RustDesk สร้าง ID จาก MAC address การลบไฟล์ตั้งค่าจึงได้ ID เดิมกลับมา โปรแกรมนี้จึงสุ่ม ID ตัวเลข 10 หลักใหม่
เขียนลง `RustDesk.toml` ของ root และทุก user แล้วลบ key pair ให้ RustDesk สร้างใหม่
ถ้า ID ชนกับเครื่องอื่น RustDesk จะสุ่มให้ใหม่เอง รหัสผ่านถาวร (Permanent Password) เดิมยังใช้ได้

## ไฟล์ที่เกี่ยวข้อง

- ไฟล์ตั้งค่าเดิมสำรองไว้ที่ `/var/backups/rustdesk-renew-id/<เวลา>/`
- ประวัติการรีเซ็ต: `/var/log/rustdesk-renew-id.log`

กู้ ID เดิม:

```bash
sudo bash /var/backups/rustdesk-renew-id/<เวลา>/restore.sh
```

## ข้อควรระวัง

- คนที่ remote เข้าเครื่องผ่าน RustDesk อยู่จะหลุดทันที
- รองรับเฉพาะ RustDesk ที่ติดตั้งแบบ .deb / .rpm (มี `rustdesk.service`) ไม่รองรับ Flatpak / AppImage
