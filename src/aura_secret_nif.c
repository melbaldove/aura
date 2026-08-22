#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE

#include "erl_nif.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/fs.h>
#include <sys/syscall.h>
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

typedef struct {
    uint32_t state[8];
    uint64_t bits;
    unsigned char block[64];
    size_t used;
} sha256_ctx;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_nil;

static uint32_t rotr(uint32_t value, unsigned int bits) {
    return (value >> bits) | (value << (32 - bits));
}

static void sha256_transform(sha256_ctx *ctx, const unsigned char block[64]) {
    static const uint32_t constants[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    };
    uint32_t words[64];
    for (size_t i = 0; i < 16; i++) {
        words[i] = ((uint32_t)block[i * 4] << 24) |
                   ((uint32_t)block[i * 4 + 1] << 16) |
                   ((uint32_t)block[i * 4 + 2] << 8) |
                   (uint32_t)block[i * 4 + 3];
    }
    for (size_t i = 16; i < 64; i++) {
        uint32_t s0 = rotr(words[i - 15], 7) ^ rotr(words[i - 15], 18) ^ (words[i - 15] >> 3);
        uint32_t s1 = rotr(words[i - 2], 17) ^ rotr(words[i - 2], 19) ^ (words[i - 2] >> 10);
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }
    uint32_t a=ctx->state[0], b=ctx->state[1], c=ctx->state[2], d=ctx->state[3];
    uint32_t e=ctx->state[4], f=ctx->state[5], g=ctx->state[6], h=ctx->state[7];
    for (size_t i = 0; i < 64; i++) {
        uint32_t s1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
        uint32_t choice = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + s1 + choice + constants[i] + words[i];
        uint32_t s0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + majority;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
    ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}

static void sha256_init(sha256_ctx *ctx) {
    static const uint32_t initial[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
        0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    memcpy(ctx->state, initial, sizeof(initial));
    ctx->bits = 0;
    ctx->used = 0;
}

static void sha256_update(sha256_ctx *ctx, const unsigned char *data, size_t size) {
    ctx->bits += (uint64_t)size * 8;
    while (size > 0) {
        size_t space = 64 - ctx->used;
        size_t take = size < space ? size : space;
        memcpy(ctx->block + ctx->used, data, take);
        ctx->used += take;
        data += take;
        size -= take;
        if (ctx->used == 64) {
            sha256_transform(ctx, ctx->block);
            ctx->used = 0;
        }
    }
}

static void sha256_final(sha256_ctx *ctx, unsigned char output[32]) {
    ctx->block[ctx->used++] = 0x80;
    if (ctx->used > 56) {
        while (ctx->used < 64) ctx->block[ctx->used++] = 0;
        sha256_transform(ctx, ctx->block);
        ctx->used = 0;
    }
    while (ctx->used < 56) ctx->block[ctx->used++] = 0;
    for (int i = 7; i >= 0; i--) ctx->block[ctx->used++] = (unsigned char)(ctx->bits >> (i * 8));
    sha256_transform(ctx, ctx->block);
    for (size_t i = 0; i < 8; i++) {
        output[i*4]=(unsigned char)(ctx->state[i]>>24);
        output[i*4+1]=(unsigned char)(ctx->state[i]>>16);
        output[i*4+2]=(unsigned char)(ctx->state[i]>>8);
        output[i*4+3]=(unsigned char)ctx->state[i];
    }
}

static ERL_NIF_TERM error_term(ErlNifEnv *env, const char *code) {
    ERL_NIF_TERM value;
    unsigned char *bytes = enif_make_new_binary(env, strlen(code), &value);
    memcpy(bytes, code, strlen(code));
    return enif_make_tuple2(env, atom_error, value);
}

static int get_string(ErlNifEnv *env, ERL_NIF_TERM term, char *buffer, size_t size) {
    ErlNifBinary binary;
    if (!enif_inspect_binary(env, term, &binary) || binary.size == 0 || binary.size >= size) return 0;
    if (memchr(binary.data, '\0', binary.size) != NULL) return 0;
    memcpy(buffer, binary.data, binary.size);
    buffer[binary.size] = '\0';
    return 1;
}

static int safe_component(const char *value) {
    if (value[0] == '\0' || strcmp(value, ".") == 0 || strcmp(value, "..") == 0) return 0;
    return strchr(value, '/') == NULL;
}

static int private_directory(int fd, int anchor) {
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid()) return 0;
    if (anchor) return (st.st_mode & 0022) == 0;
    return (st.st_mode & 0777) == 0700;
}

static int open_directory_at(int parent, const char *name, const char **error) {
    struct stat entry;
    if (fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0) {
        *error = "secret_parent_unavailable";
        return -1;
    }
    if (S_ISLNK(entry.st_mode)) {
        *error = "secret_parent_symlink_rejected";
        return -1;
    }
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        *error = "secret_parent_unavailable";
        return -1;
    }
    return fd;
}

static int open_anchor(const char *anchor, int create, const char **error) {
    const char *walk_anchor = anchor;
#ifdef __APPLE__
    char normalized[4097];
    if (strcmp(anchor, "/tmp") == 0 || strncmp(anchor, "/tmp/", 5) == 0) {
        snprintf(normalized, sizeof(normalized), "/private%s", anchor);
        walk_anchor = normalized;
    }
#endif
    if (walk_anchor[0] != '/') { *error = "secret_parent_unavailable"; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { *error = "secret_parent_unavailable"; return -1; }
    char copy[4097];
    if (strlen(walk_anchor) >= sizeof(copy)) { close(fd); *error = "secret_parent_unavailable"; return -1; }
    strcpy(copy, walk_anchor);
    char *save = NULL;
    char *part = strtok_r(copy, "/", &save);
    while (part != NULL) {
        if (!safe_component(part)) { close(fd); *error = "secret_parent_unavailable"; return -1; }
        int created = 0;
        if (create && mkdirat(fd, part, 0700) == 0) created = 1;
        else if (create && errno != EEXIST) { close(fd); *error = "secret_parent_create_failed"; return -1; }
        int next = open_directory_at(fd, part, error);
        if (next < 0) { close(fd); return -1; }
        if (created && fchmod(next, 0700) != 0) {
            close(next); close(fd); *error = "secret_parent_permissions_failed"; return -1;
        }
        close(fd);
        fd = next;
        part = strtok_r(NULL, "/", &save);
    }
    if (!private_directory(fd, 1)) { close(fd); *error = "secret_parent_permissions_invalid"; return -1; }
    return fd;
}

static int open_private_chain(const char *anchor, const char *relative, int create, const char **error) {
    int fd = open_anchor(anchor, create, error);
    if (fd < 0) return -1;
    char copy[513];
    if (strlen(relative) == 0 || strlen(relative) >= sizeof(copy)) { close(fd); *error = "secret_relative_directory_invalid"; return -1; }
    strcpy(copy, relative);
    char *save = NULL;
    char *part = strtok_r(copy, "/", &save);
    while (part != NULL) {
        if (!safe_component(part)) { close(fd); *error = "secret_relative_directory_invalid"; return -1; }
        int created = 0;
        if (create && mkdirat(fd, part, 0700) == 0) created = 1;
        else if (create && errno != EEXIST) {
            close(fd); *error = "secret_parent_create_failed"; return -1;
        }
        int next = open_directory_at(fd, part, error);
        if (next < 0) { close(fd); return -1; }
        if (created && fchmod(next, 0700) != 0) {
            close(next); close(fd); *error = "secret_parent_permissions_failed"; return -1;
        }
        if (!private_directory(next, 0)) { close(next); close(fd); *error = "secret_parent_permissions_invalid"; return -1; }
        close(fd);
        fd = next;
        part = strtok_r(NULL, "/", &save);
    }
    return fd;
}

static int validate_secret_fd(int fd, size_t maximum, struct stat *st, const char **error) {
    if (fstat(fd, st) != 0) { *error = "secret_file_unavailable"; return 0; }
    if (!S_ISREG(st->st_mode)) { *error = "secret_type_invalid"; return 0; }
    if (st->st_uid != geteuid()) { *error = "secret_owner_invalid"; return 0; }
    if ((st->st_mode & 0777) != 0600) { *error = "secret_permissions_invalid"; return 0; }
    if ((uint64_t)st->st_size > maximum) { *error = "secret_file_too_large"; return 0; }
    return 1;
}

static int read_all(int fd, unsigned char *bytes, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = pread(fd, bytes + offset, size - offset, (off_t)offset);
        if (count <= 0) return 0;
        offset += (size_t)count;
    }
    unsigned char extra;
    return pread(fd, &extra, 1, (off_t)size) == 0;
}

static ERL_NIF_TERM create_exclusive_beneath(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char anchor[4097], relative[513], name[193];
    ErlNifBinary contents;
    if (argc != 4 || !get_string(env, argv[0], anchor, sizeof(anchor)) ||
        !get_string(env, argv[1], relative, sizeof(relative)) ||
        !get_string(env, argv[2], name, sizeof(name)) || !safe_component(name) ||
        !enif_inspect_binary(env, argv[3], &contents)) return enif_make_badarg(env);
    const char *error = NULL;
    int directory = open_private_chain(anchor, relative, 1, &error);
    if (directory < 0) return error_term(env, error);
    char temporary[193];
    snprintf(temporary, sizeof(temporary), ".pending-%ld-%lld", (long)getpid(),
             (long long)enif_monotonic_time(ERL_NIF_NSEC));
    int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { close(directory); return error_term(env, "secret_write_failed"); }
    int good = fchmod(fd, 0600) == 0;
    size_t offset = 0;
    while (good && offset < contents.size) {
        ssize_t count = write(fd, contents.data + offset, contents.size - offset);
        if (count <= 0) good = 0; else offset += (size_t)count;
    }
    if (good) good = fsync(fd) == 0;
    struct stat st;
    if (good) good = validate_secret_fd(fd, contents.size, &st, &error);
    if (!good) {
        close(fd); unlinkat(directory, temporary, 0); close(directory);
        return error_term(env, error == NULL ? "secret_write_failed" : error);
    }
    if (linkat(directory, temporary, directory, name, 0) != 0) {
        int link_error = errno;
        close(fd); unlinkat(directory, temporary, 0); close(directory);
        return error_term(env, link_error == EEXIST ? "secret_already_exists" : "secret_write_failed");
    }
    struct stat published;
    good = fstatat(directory, name, &published, AT_SYMLINK_NOFOLLOW) == 0 &&
           published.st_dev == st.st_dev && published.st_ino == st.st_ino;
    close(fd);
    if (!good || unlinkat(directory, temporary, 0) != 0 || fsync(directory) != 0) {
        unlinkat(directory, name, 0);
        unlinkat(directory, temporary, 0);
        close(directory);
        return error_term(env, "secret_write_failed");
    }
    close(directory);
    return enif_make_tuple2(env, atom_ok, atom_nil);
}

static ERL_NIF_TERM secure_read_beneath(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char anchor[4097], relative[513], name[193];
    unsigned int maximum;
    if (argc != 4 || !get_string(env, argv[0], anchor, sizeof(anchor)) ||
        !get_string(env, argv[1], relative, sizeof(relative)) ||
        !get_string(env, argv[2], name, sizeof(name)) || !safe_component(name) ||
        !enif_get_uint(env, argv[3], &maximum)) return enif_make_badarg(env);
    const char *error = NULL;
    int directory = open_private_chain(anchor, relative, 0, &error);
    if (directory < 0) return error_term(env, error);
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    close(directory);
    if (fd < 0) return error_term(env, errno == ELOOP ? "secret_symlink_rejected" : "secret_file_unavailable");
    struct stat st;
    if (!validate_secret_fd(fd, maximum, &st, &error)) { close(fd); return error_term(env, error); }
    ERL_NIF_TERM value;
    unsigned char *bytes = enif_make_new_binary(env, (size_t)st.st_size, &value);
    if (!read_all(fd, bytes, (size_t)st.st_size)) { close(fd); return error_term(env, "secret_file_unavailable"); }
    close(fd);
    return enif_make_tuple2(env, atom_ok, value);
}

static int digest_matches(const unsigned char *bytes, size_t size, const char *expected);
static int same_content_state(const struct stat *left, const struct stat *right);

static ERL_NIF_TERM replace_exact_beneath(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char anchor[4097], relative[513], name[193], expected[65];
    ErlNifBinary contents;
    if (argc != 5 || !get_string(env, argv[0], anchor, sizeof(anchor)) ||
        !get_string(env, argv[1], relative, sizeof(relative)) ||
        !get_string(env, argv[2], name, sizeof(name)) || !safe_component(name) ||
        !get_string(env, argv[3], expected, sizeof(expected)) || strlen(expected) != 64 ||
        !enif_inspect_binary(env, argv[4], &contents) || contents.size > 65536) {
        return enif_make_badarg(env);
    }
    const char *error = NULL;
    int directory = open_private_chain(anchor, relative, 0, &error);
    if (directory < 0) return error_term(env, error);
    int current = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (current < 0) {
        close(directory);
        return error_term(env, errno == ELOOP ? "secret_symlink_rejected" : "secret_file_unavailable");
    }
    struct stat before, after, named;
    unsigned char current_bytes[65536];
    int stable = validate_secret_fd(current, 65536, &before, &error) &&
                 read_all(current, current_bytes, (size_t)before.st_size) &&
                 fstat(current, &after) == 0 && same_content_state(&before, &after) &&
                 fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                 named.st_dev == after.st_dev && named.st_ino == after.st_ino;
    if (!stable || !digest_matches(current_bytes, (size_t)before.st_size, expected)) {
        close(current); close(directory);
        return error_term(env, stable ? "secret_hash_mismatch" : "secret_path_changed");
    }
    char temporary[193];
    snprintf(temporary, sizeof(temporary), ".replace-%ld-%lld", (long)getpid(),
             (long long)enif_monotonic_time(ERL_NIF_NSEC));
    int replacement = openat(directory, temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (replacement < 0) {
        close(current); close(directory);
        return error_term(env, "secret_write_failed");
    }
    int good = fchmod(replacement, 0600) == 0;
    size_t offset = 0;
    while (good && offset < contents.size) {
        ssize_t count = write(replacement, contents.data + offset, contents.size - offset);
        if (count <= 0) good = 0; else offset += (size_t)count;
    }
    if (good) good = fsync(replacement) == 0;
    struct stat replacement_stat;
    if (good) good = validate_secret_fd(replacement, contents.size, &replacement_stat, &error);
    if (good) {
        struct stat final_current, final_named;
        good = fstat(current, &final_current) == 0 &&
               same_content_state(&after, &final_current) &&
               fstatat(directory, name, &final_named, AT_SYMLINK_NOFOLLOW) == 0 &&
               final_named.st_dev == final_current.st_dev &&
               final_named.st_ino == final_current.st_ino;
    }
    close(replacement);
    close(current);
    if (!good) {
        unlinkat(directory, temporary, 0); close(directory);
        return error_term(env, error == NULL ? "secret_path_changed" : error);
    }
    if (renameat(directory, temporary, directory, name) != 0 || fsync(directory) != 0) {
        unlinkat(directory, temporary, 0); close(directory);
        return error_term(env, "secret_replace_failed");
    }
    close(directory);
    return enif_make_tuple2(env, atom_ok, atom_nil);
}

static int digest_matches(const unsigned char *bytes, size_t size, const char *expected) {
    unsigned char digest[32];
    char hex[65];
    static const char alphabet[] = "0123456789abcdef";
    sha256_ctx ctx;
    sha256_init(&ctx); sha256_update(&ctx, bytes, size); sha256_final(&ctx, digest);
    for (size_t i = 0; i < 32; i++) { hex[i*2]=alphabet[digest[i]>>4]; hex[i*2+1]=alphabet[digest[i]&15]; }
    hex[64] = '\0';
    unsigned char different = 0;
    for (size_t i = 0; i < 64; i++) different |= (unsigned char)(hex[i] ^ expected[i]);
    return different == 0;
}

static int rename_noreplace(int directory, const char *source, const char *target) {
#ifdef __APPLE__
    return renameatx_np(directory, source, directory, target, RENAME_EXCL);
#elif defined(__linux__)
    return (int)syscall(SYS_renameat2, directory, source, directory, target, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

static int same_content_state(const struct stat *left, const struct stat *right) {
    if (left->st_dev != right->st_dev || left->st_ino != right->st_ino ||
        left->st_size != right->st_size) return 0;
#ifdef __APPLE__
    return left->st_mtimespec.tv_sec == right->st_mtimespec.tv_sec &&
           left->st_mtimespec.tv_nsec == right->st_mtimespec.tv_nsec &&
           left->st_ctimespec.tv_sec == right->st_ctimespec.tv_sec &&
           left->st_ctimespec.tv_nsec == right->st_ctimespec.tv_nsec;
#else
    return left->st_mtim.tv_sec == right->st_mtim.tv_sec &&
           left->st_mtim.tv_nsec == right->st_mtim.tv_nsec &&
           left->st_ctim.tv_sec == right->st_ctim.tv_sec &&
           left->st_ctim.tv_nsec == right->st_ctim.tv_nsec;
#endif
}

static ERL_NIF_TERM restore_remove_tomb(ErlNifEnv *env, int directory,
                                        const char *tomb, const char *name,
                                        const char *error) {
    int restored = rename_noreplace(directory, tomb, name) == 0;
    close(directory);
    return error_term(env, restored ? error : "secret_restore_failed");
}

static ERL_NIF_TERM remove_exact_beneath(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char anchor[4097], relative[513], name[193], expected[65];
    if (argc != 4 || !get_string(env, argv[0], anchor, sizeof(anchor)) ||
        !get_string(env, argv[1], relative, sizeof(relative)) ||
        !get_string(env, argv[2], name, sizeof(name)) || !safe_component(name) ||
        !get_string(env, argv[3], expected, sizeof(expected)) || strlen(expected) != 64) return enif_make_badarg(env);
    const char *error = NULL;
    int directory = open_private_chain(anchor, relative, 0, &error);
    if (directory < 0) return error_term(env, error);
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { close(directory); return error_term(env, errno == ELOOP ? "secret_symlink_rejected" : "secret_file_unavailable"); }
    struct stat opened;
    if (!validate_secret_fd(fd, 65536, &opened, &error)) { close(fd); close(directory); return error_term(env, error); }
    char tomb[193];
    snprintf(tomb, sizeof(tomb), ".remove-%ld-%d", (long)getpid(), fd);
    if (rename_noreplace(directory, name, tomb) != 0) { close(fd); close(directory); return error_term(env, "secret_remove_failed"); }
    struct stat moved;
    int same = fstatat(directory, tomb, &moved, AT_SYMLINK_NOFOLLOW) == 0 && opened.st_dev == moved.st_dev && opened.st_ino == moved.st_ino;
    if (!same) {
        close(fd);
        return restore_remove_tomb(env, directory, tomb, name, "secret_path_changed");
    }
    unsigned char contents[65536];
    struct stat before_hash, after_hash, before_unlink;
    int stable = validate_secret_fd(fd, 65536, &before_hash, &error) &&
                 read_all(fd, contents, (size_t)before_hash.st_size) &&
                 fstat(fd, &after_hash) == 0 &&
                 same_content_state(&before_hash, &after_hash);
    if (!stable || !digest_matches(contents, (size_t)before_hash.st_size, expected)) {
        close(fd);
        return restore_remove_tomb(env, directory, tomb, name,
                                   stable ? "secret_hash_mismatch" : "secret_path_changed");
    }
    stable = fstat(fd, &before_unlink) == 0 &&
             same_content_state(&after_hash, &before_unlink);
    close(fd);
    if (!stable) return restore_remove_tomb(env, directory, tomb, name, "secret_path_changed");
    int removed = unlinkat(directory, tomb, 0) == 0;
    close(directory);
    return removed ? enif_make_tuple2(env, atom_ok, atom_nil) : error_term(env, "secret_remove_failed");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv; (void)info;
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_nil = enif_make_atom(env, "nil");
    return 0;
}

static ErlNifFunc functions[] = {
    {"create_exclusive_beneath", 4, create_exclusive_beneath, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"secure_read_beneath", 4, secure_read_beneath, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"remove_exact_beneath", 4, remove_exact_beneath, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"replace_exact_beneath", 5, replace_exact_beneath, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(aura_secret_nif, functions, load, NULL, NULL, NULL)
