# Развертывание Gitea с помощью Ansible в Docker

## Описание проекта

Этот проект предназначен для автоматического развертывания Gitea (системы управления Git репозиториями) в Docker контейнере на целевом сервере с Debian 13. Для запуска используется Ansible, который сам работает внутри Docker контейнера.

## Структура проекта

```
.
├── Dockerfile                      # Файл для сборки Docker образа с Ansible
├── ansible/
│   ├── ansible.cfg                 # Конфигурация Ansible
│   ├── inventory.ini               # Список целевых серверов
│   └── deploy-gitea.yml            # Playbook для развертывания Gitea
└── README.md                       # Этот файл
```

## Что внутри

### Dockerfile
Docker образ на базе Debian 13 с установленным Ansible и необходимыми инструментами (openssh-client, sshpass, git).

### ansible/deploy-gitea.yml
Ansible playbook который:
- Устанавливает Docker на целевой сервер
- Создает директорию для данных Gitea
- Запускает Gitea в Docker контейнере
- Настраивает порты 80 (web) и 22 (ssh для git)

## Подготовка окружения
Всё протестированно на kubuntu 25.10

### Вариант 1: Развертывание на виртуальной машине QEMU (192.168.35.35)

#### Шаг 1: Установка QEMU на локальной машине

Устанавливаем QEMU и необходимые пакеты:

```bash
sudo apt update
sudo apt install qemu-system-x86 qemu-utils bridge-utils
```

#### Шаг 2: Скачивание образа Debian 13

Скачиваем ISO образ Debian 13:

```bash
cd ~
mkdir -p qemu-vms
cd qemu-vms
wget https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.3.0-amd64-netinst.iso
```

#### Шаг 3: Создание виртуального диска

Создаем виртуальный диск размером 20GB:

```bash
qemu-img create -f qcow2 debian-gitea.qcow2 20G
```

#### Шаг 4: Установка Debian на виртуальную машину

Запускаем установку Debian:

```bash
qemu-system-x86_64 \
  -enable-kvm -cpu host \
  -m 2048 \
  -smp 2 \
  -drive file=debian-gitea.qcow2,if=virtio,format=qcow2,cache=none \
  -cdrom debian-13.3.0-amd64-netinst.iso \
  -boot d \
  -netdev user,id=n1 \
  -device virtio-net-pci,netdev=n1
```

Во время установки:
- Выберите язык английский
- Лучше избегать графической установки (выбрать пункт install)
- hostname `debian-gitea`
- Использовать весь диск и все файлы в одной директории
- Создайте пользователя `debian` с паролем который запомните
- Установите SSH server и стандартные системные утилиты когда предложит выбрать, не стоит ставить Gnome и графический интерфейс
- Завершите установку и перезагрузитесь

#### Шаг 5: Настройка сети для доступа по IP 192.168.35.35

После установки выключите виртуальную машину и настроим сеть.

Создаем bridge интерфейс на хостовой машине:

```bash
sudo ip link add br0 type bridge
sudo ip addr add 192.168.35.1/24 dev br0
sudo ip link set br0 up
```

Создаем TAP интерфейс:

```bash
sudo ip tuntap add dev tap0 mode tap
sudo ip link set tap0 master br0
sudo ip link set tap0 up
```

Включаем IP forwarding:

```bash
# 1) включить форвардинг
sudo sysctl -w net.ipv4.ip_forward=1

# 2) узнать интерфейс в интернет (вставь вместо $(...) вручную, если хочешь)
WAN_IF="$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
echo "WAN_IF=$WAN_IF"

# 3) разрешить форвардинг br0 -> WAN и обратно (ESTABLISHED)
sudo iptables -C FORWARD -i br0 -o "$WAN_IF" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -i br0 -o "$WAN_IF" -j ACCEPT
sudo iptables -C FORWARD -i "$WAN_IF" -o br0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -i "$WAN_IF" -o br0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 4) NAT (MASQUERADE) именно в сторону WAN
sudo iptables -t nat -C POSTROUTING -s 192.168.35.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null || sudo iptables -t nat -A POSTROUTING -s 192.168.35.0/24 -o "$WAN_IF" -j MASQUERADE
```

Настраиваем NAT для доступа виртуальной машины в интернет:

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.35.0/24 -j MASQUERADE
```

#### Шаг 6: Запуск виртуальной машины 

```bash
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -drive file=debian-gitea.qcow2,if=virtio,format=qcow2,cache=none \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0

```

#### Шаг 7: Настройка сети внутри виртуальной машины

Войдите в виртуальную машину (используя консоль QEMU) и настройте сеть:

```bash
# Войдите под пользователем debian
# Отредактируйте файл /etc/network/interfaces
su 
nano /etc/network/interfaces
```

Добавьте следующие строки:

```
auto ens3
iface ens3 inet static
    address 192.168.35.35
    netmask 255.255.255.0
    gateway 192.168.35.1
    dns-nameservers 1.1.1.1
```

Сохраните файл (Ctrl+O, Enter, Ctrl+X).

Перезапустите сеть:
```bash
systemctl restart networking
```
Проверьте что IP адрес назначен:

```bash
ip a
```
#### Шаг 8: Проверка доступности с хостовой машины

На хостовой машине проверьте доступность виртуальной машины:

```bash
ping 192.168.35.35
```
На этом этапе уже можно подключиться к виртуальной машине по ssh для удобства (вводим пароль ранее назначенный пользователю debian)

```bash
ssh debian@192.168.35.35
```

#### Шаг 9: Настройка DNS сервера и доступа в интернет на виртуальной машине QEMU (debian-gitea)

Прописать DNS сервер:
```bash
su
printf "nameserver 1.1.1.1" > /etc/resolv.conf
apt update
```

Проверьте что есть доступ в интернет

```bash
ping 8.8.8.8
```

Остановить dhcpcd (по процессам):
```
pkill dhcpcd
```

Установить и включить resolvconf (для  того чтобы DNS работал после перезагрузки):
```bash
apt update
apt install -y resolvconf
systemctl enable --now resolvconf || true
systemctl restart networking
```


#### Шаг 10: Установка и настройка sudo в QEMU VM (обязательный bootstrap для Ansible)

Ansible будет подключаться **как пользователь `debian` по SSH-ключу** и выполнять команды через **`sudo` без пароля**
(чтобы не было никаких интерактивных подтверждений).

Выполните это **внутри QEMU VM** (через консоль VM или любым способом, где у вас уже есть root-доступ):

```bash
apt install -y sudo
usermod -aG sudo debian
```
Если видим ошибку
```bash
bash: usermod: command not found

# 1) Проверяем, есть ли бинарник
ls -l /usr/sbin/usermod || true

# 2) Если есть — запускаем по полному пути
/usr/sbin/usermod -aG sudo debian

# 3) Если файла нет — ставим пакет и повторяем
apt-get update
apt-get install -y passwd
/usr/sbin/usermod -aG sudo debian
```
Перезагружаем виртуальную машину
Запуск виртуальной машины описан в шаге 6 не забываем перейти в папку с QEMU 
```bash
cd /path/to/gitea-ansible-task/qemu-vms
```

```bash
# Passwordless sudo for automation (NOPASSWD)
su
install -d -m 0755 /etc/sudoers.d
printf 'debian ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-debian-nopasswd
chmod 0440 /etc/sudoers.d/90-debian-nopasswd

# Проверка (не должно спрашивать пароль)
su - debian -c 'sudo -n true'
```



#### Шаг 10: Настройка inventory для QEMU VM

Откройте файл `ansible/inventory.ini` и раскомментируйте строку для QEMU VM:

```ini
[gitea_servers]
gitea-vm ansible_host=192.168.35.35 ansible_user=debian ansible_ssh_private_key_file=/ansible/.ssh/deb_gitea ansible_become=true ansible_become_method=sudo ansible_become_flags=-n
```
Ключ `deb_gitea` должен лежать в `ansible/.ssh/` на хостовой машине и пробрасываться в контейнер через `-v $(pwd)/ansible:/ansible`.

### Вариант 2. Предпочтительный: Вход по ssh ключу ( подходит для использования на удаленном сервере)

Если у вас есть удаленный сервер с Debian 13 и SSH доступом:

#### Шаг 1: Подготовка SSH ключей

На вашей локальной машине сгенерируйте SSH ключ:

Переходим в папку проекта
```bash
cd /path/to/gitea-ansible-task
```
```bash
cd ..
mkdir -p ansible/.ssh
ssh-keygen -t rsa -b 4096 -f ansible/.ssh/deb_gitea -N ""
```

Скопируйте ключ на удаленный сервер (запросит пароль пользователя debian):

```bash
ssh-copy-id -i ansible/.ssh/deb_gitea.pub debian@192.168.35.35
```
Вводим пароль от пользователя debian

Проверяем доступ по ключу (не должно спрашивать пароль при входе)

```bash
ssh -i ansible/.ssh/deb_gitea debian@192.168.35.35
```

#### Шаг 2: Настройка inventory для удаленного сервера

Откройте файл `ansible/inventory.ini` и раскомментируйте строку для удаленного сервера:

```ini
[gitea_servers]
gitea-remote ansible_host=your_server_ip ansible_user=your_user ansible_ssh_private_key_file= .ssh/deb_gitea
```


Замените:
- `your_server_ip` на реальный IP адрес вашего сервера
- `your_user` на имя пользователя с sudo правами

## Развертывание Gitea

### Шаг 1: Сборка Docker образа с Ansible

Перейдите в директорию проекта:

```bash
cd /path/to/gitea-ansible-task
```

Соберите Docker образ:

```bash
docker build -t ansible-debian:local .
```

Процесс займет несколько минут. Docker скачает базовый образ Debian 13 и установит Ansible с зависимостями.


### Шаг 2: Запуск Ansible из Docker контейнера

Для удаленного сервера (с SSH ключом):

```bash
docker run -it --rm \
  -v $(pwd)/ansible:/ansible \
  ansible-debian:local \
  ansible-playbook deploy-gitea.yml
```

Важно для QEMU VM: запуск без паролей/подтверждений делается через SSH-ключ под `root`
(см. `ansible/inventory.ini`, где для `gitea-vm` указан `ansible_user=root`).
Убедитесь, что публичный ключ добавлен в `/root/.ssh/authorized_keys` на VM и
в `sshd_config` разрешен вход по ключу для root (рекомендуемо `PermitRootLogin prohibit-password`).

### Шаг 3: Ожидание завершения

Ansible выполнит следующие действия:
1. Обновит кеш пакетов apt
2. Установит необходимые зависимости
3. Добавит официальный репозиторий Docker
4. Установит Docker
5. Создаст директорию для данных Gitea
6. Запустит контейнер Gitea
7. Дождется запуска сервиса

Процесс займет 5-10 минут в зависимости от скорости интернета.

### Шаг 5: Проверка развертывания

После успешного завершения откройте браузер и перейдите по адресу:

Для QEMU VM:
```
http://192.168.35.35
```

Для удаленного сервера:
```
http://your_server_ip
```

Вы должны увидеть страницу первоначальной настройки Gitea.

## Работа с Gitea

### Первоначальная настройка

При первом входе Gitea предложит настроить базу данных и административный аккаунт:

1. Выберите SQLite3 в качестве базы данных (по умолчанию)
2. Оставьте остальные настройки по умолчанию
3. Создайте административный аккаунт
4. Нажмите "Install Gitea"

### Работа с Git репозиториями

После настройки вы можете создавать репозитории и работать с ними через Git.

Клонирование репозитория для QEMU VM:

```bash
git clone ssh://git@192.168.35.35:2222/username/repository.git
```

Клонирование репозитория для удаленного сервера:

```bash
git clone ssh://git@your_server_ip:2222/username/repository.git
```

## Как это работает

### Docker образ с Ansible

Dockerfile создает образ на базе Debian 13 и устанавливает:
- `ansible` - система управления конфигурациями
- `openssh-client` - для SSH соединений с целевыми серверами
- `sshpass` - для аутентификации по паролю (для QEMU VM)
- `git` - на случай если понадобится клонировать репозитории

### Ansible Playbook

Playbook `deploy-gitea.yml` описывает последовательность действий:

1. **Обновление кеша пакетов** - гарантирует что установятся последние версии
2. **Установка зависимостей** - пакеты необходимые для добавления репозитория Docker
3. **Добавление GPG ключа Docker** - для проверки подлинности пакетов
4. **Добавление репозитория Docker** - официальный источник пакетов Docker
5. **Установка Docker** - из официального репозитория Docker (не из Debian)
6. **Запуск Docker** - активация сервиса и добавление в автозагрузку
7. **Создание директории** - `/opt/gitea` для хранения данных
8. **Остановка старого контейнера** - если Gitea уже был установлен
9. **Запуск Gitea** - создание и запуск контейнера с правильными портами и томом

### Переменные в Playbook

В начале playbook определены переменные:
- `gitea_version: "latest"` - использовать последнюю версию Gitea
- `gitea_http_port: "80"` - веб-интерфейс на 80 порту
- `gitea_ssh_port: "2222"` - SSH для Git (22 порт занят системным SSH)
- `gitea_data_dir: "/opt/gitea"` - где хранятся данные

Вы можете изменить эти значения если нужны другие порты.

### Почему Docker внутри Docker

Ansible работает из Docker контейнера чтобы:
- Не засорять локальную систему зависимостями
- Иметь одинаковое окружение на любой машине
- Легко делиться проектом с коллегами

## Возможные проблемы и решения

### Проблема: Ansible не может подключиться к хосту

Решение:
- Проверьте что целевой хост доступен: `ping 192.168.35.35`
- Проверьте SSH доступ: `ssh debian@192.168.35.35`
- Проверьте правильность пароля/ключа в inventory.ini

### Проблема: `/bin/sh: 1: sudo: not found` (падает на Gathering Facts)

Причина: playbook запускается с `become: yes`, а на минимальной установке Debian `sudo` может быть не установлен. В итоге Ansible не может повысить привилегии и ломается ещё на сборе фактов.

Решение (на целевом хосте, Debian 13):

1) Зайдите на хост и получите root (например, в консоли VM):

```bash
ssh debian@192.168.35.35
su -
```

2) Установите `sudo` и добавьте пользователя в группу `sudo`:

```bash
apt update
apt install -y sudo
usermod -aG sudo debian
```

3) Перезайдите по SSH (чтобы подтянулись группы) и проверьте:

```bash
exit
ssh debian@192.168.35.35
sudo -n true || sudo true
```

Опционально (только для лабораторной VM): можно включить passwordless sudo для Ansible:

```bash
su -
printf '%s\n' 'debian ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-debian-nopasswd
chmod 0440 /etc/sudoers.d/99-debian-nopasswd
```

### Проблема: Docker не устанавливается

Решение:
- Убедитесь что на целевом хосте Debian 13
- Проверьте доступ в интернет с целевого хоста
- Попробуйте вручную добавить репозиторий Docker

### Проблема: Порт 80 или 22 уже занят

Решение:
- Измените переменные в playbook на другие порты (например 8080 и 2222)
- Остановите службы занимающие эти порты на целевом хосте

### Проблема: QEMU VM не получает IP 192.168.35.35

Решение:
- Проверьте что bridge и tap интерфейсы созданы: `ip addr`
- Проверьте настройки сети внутри VM: `cat /etc/network/interfaces`
- Перезапустите сеть в VM: `systemctl restart networking`

## Дополнительные команды

### Проверка статуса Gitea на целевом хосте

```bash
ssh debian@192.168.35.35
sudo docker ps
sudo docker logs gitea
```

### Остановка Gitea

```bash
ssh debian@192.168.35.35
sudo docker stop gitea
```

### Запуск Gitea

```bash
ssh debian@192.168.35.35
sudo docker start gitea
```

### Повторный запуск playbook

Если что-то пошло не так, можно запустить playbook повторно - он идемпотентный (безопасно запускать много раз).

## Требования

### Локальная машина
- Linux с установленным Docker
- Доступ в интернет

### Целевой сервер
- Debian 13
- Минимум 1GB RAM
- Минимум 10GB свободного места на диске
- SSH доступ
- Доступ в интернет

## Автор
Кармазин Вячеслав
Проект создан в качестве тестового задания для позиции DevOps инженера.
