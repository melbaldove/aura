-module(aura_secret_ffi).
-export([atomic_write/2, create_exclusive/2, random_bytes/1, hmac_sha256/2,
         sha256/1, constant_time_equal/2, effective_uid/0,
         secure_read/2, create_exclusive_beneath/4,
         secure_read_beneath/4, remove_exact_beneath/4,
         replace_exact_beneath/5]).

-include_lib("kernel/include/file.hrl").

atomic_write(Path, Contents) when is_binary(Path), is_binary(Contents) ->
    PathList = binary_to_list(Path),
    Directory = filename:dirname(PathList),
    case filelib:ensure_dir(PathList) of
        ok ->
            case file:change_mode(Directory, 8#700) of
                ok -> write_temp(PathList, Contents);
                {error, _} -> {error, <<"secret_parent_permissions_failed">>}
            end;
        {error, _} -> {error, <<"secret_parent_create_failed">>}
    end.

create_exclusive(Path, Contents) when is_binary(Path), is_binary(Contents) ->
    PathList = binary_to_list(Path),
    Directory = filename:dirname(PathList),
    case filelib:ensure_dir(PathList) of
        ok ->
            case file:change_mode(Directory, 8#700) of
                ok -> write_exclusive(PathList, Contents);
                {error, _} -> {error, <<"secret_parent_permissions_failed">>}
            end;
        {error, _} -> {error, <<"secret_parent_create_failed">>}
    end.

write_exclusive(Path, Contents) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, Handle} ->
            Result = case file:write(Handle, Contents) of
                ok -> file:sync(Handle);
                Error -> Error
            end,
            _ = file:close(Handle),
            case Result of
                ok ->
                    case file:change_mode(Path, 8#600) of
                        ok -> {ok, nil};
                        {error, _} ->
                            _ = file:delete(Path),
                            {error, <<"secret_permissions_failed">>}
                    end;
                {error, _} ->
                    _ = file:delete(Path),
                    {error, <<"secret_write_failed">>}
            end;
        {error, eexist} -> {error, <<"monitor_capability_already_exists">>};
        {error, _} -> {error, <<"secret_write_failed">>}
    end.

write_temp(Path, Contents) ->
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Temp = Path ++ ".tmp." ++ Suffix,
    case file:open(Temp, [write, binary, exclusive]) of
        {ok, Handle} -> write_and_sync(Handle, Temp, Path, Contents);
        {error, _} -> {error, <<"secret_write_failed">>}
    end.

write_and_sync(Handle, Temp, Path, Contents) ->
    Result = case file:write(Handle, Contents) of
        ok -> file:sync(Handle);
        Error -> Error
    end,
    _ = file:close(Handle),
    case Result of
        ok ->
            case file:change_mode(Temp, 8#600) of
                ok -> rename_temp(Temp, Path);
                {error, _} ->
                    _ = file:delete(Temp),
                    {error, <<"secret_permissions_failed">>}
            end;
        {error, _} ->
            _ = file:delete(Temp),
            {error, <<"secret_write_failed">>}
    end.

rename_temp(Temp, Path) ->
    case file:rename(Temp, Path) of
        ok -> {ok, nil};
        {error, _} ->
            _ = file:delete(Temp),
            {error, <<"secret_replace_failed">>}
    end.

random_bytes(Count) -> crypto:strong_rand_bytes(Count).

hmac_sha256(Key, Value) -> crypto:mac(hmac, sha256, Key, Value).

sha256(Value) -> crypto:hash(sha256, Value).

constant_time_equal(Left, Right) when byte_size(Left) =:= byte_size(Right) ->
    crypto:hash_equals(Left, Right);
constant_time_equal(_, _) -> false.

secure_read(Path, MaximumBytes) when is_binary(Path), is_integer(MaximumBytes) ->
    secure_read_path(binary_to_list(Path), MaximumBytes).

secure_read_path(Path, MaximumBytes) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> {error, <<"secret_symlink_rejected">>};
        {ok, Initial = #file_info{type = regular}} ->
            case file:open(Path, [read, binary, raw]) of
                {ok, Handle} ->
                    Result = secure_read_handle(Path, Handle, Initial, MaximumBytes),
                    _ = file:close(Handle),
                    Result;
                {error, _} -> {error, <<"secret_file_unavailable">>}
            end;
        {ok, _} -> {error, <<"secret_type_invalid">>};
        {error, _} -> {error, <<"secret_file_unavailable">>}
    end.

secure_read_handle(Path, Handle, Initial, MaximumBytes) ->
    case {file:read_file_info(Handle), file:read_link_info(Path)} of
        {{ok, Opened}, {ok, Current}} ->
            case same_file_identity(Initial, Opened) andalso
                 same_file_identity(Opened, Current) of
                false -> {error, <<"secret_path_changed">>};
                true ->
                    case validate_private_regular(Opened, MaximumBytes) of
                        ok -> read_bounded(Handle, MaximumBytes);
                        Error -> Error
                    end
            end;
        _ -> {error, <<"secret_file_unavailable">>}
    end.

read_bounded(Handle, MaximumBytes) ->
    case file:read(Handle, MaximumBytes + 1) of
        eof -> {ok, <<>>};
        {ok, Bytes} when byte_size(Bytes) =< MaximumBytes ->
            case file:read(Handle, 1) of
                eof -> {ok, Bytes};
                _ -> {error, <<"secret_file_too_large">>}
            end;
        {ok, _} -> {error, <<"secret_file_too_large">>};
        {error, _} -> {error, <<"secret_file_unavailable">>}
    end.

create_exclusive_beneath(Anchor, Relative, FileName, Contents)
  when is_binary(Anchor), is_binary(Relative), is_binary(FileName), is_binary(Contents) ->
    aura_secret_nif:create_exclusive_beneath(
        Anchor, Relative, FileName, Contents).

secure_read_beneath(Anchor, Relative, FileName, MaximumBytes)
  when is_binary(Anchor), is_binary(Relative), is_binary(FileName), is_integer(MaximumBytes) ->
    aura_secret_nif:secure_read_beneath(
        Anchor, Relative, FileName, MaximumBytes).

remove_exact_beneath(Anchor, Relative, FileName, ExpectedDigest)
  when is_binary(Anchor), is_binary(Relative), is_binary(FileName), is_binary(ExpectedDigest) ->
    aura_secret_nif:remove_exact_beneath(
        Anchor, Relative, FileName, ExpectedDigest).

replace_exact_beneath(Anchor, Relative, FileName, ExpectedDigest, Contents)
  when is_binary(Anchor), is_binary(Relative), is_binary(FileName),
       is_binary(ExpectedDigest), is_binary(Contents) ->
    aura_secret_nif:replace_exact_beneath(
        Anchor, Relative, FileName, ExpectedDigest, Contents).

validate_private_regular(#file_info{type = regular, uid = Uid,
                                    mode = Mode, size = Size}, MaximumBytes) ->
    case Uid =:= effective_uid() of
        false -> {error, <<"secret_owner_invalid">>};
        true when Mode band 8#777 =/= 8#600 ->
            {error, <<"secret_permissions_invalid">>};
        true when Size > MaximumBytes -> {error, <<"secret_file_too_large">>};
        true -> ok
    end;
validate_private_regular(_, _) -> {error, <<"secret_type_invalid">>}.

same_file_identity(#file_info{inode = Inode, major_device = Major,
                              minor_device = Minor},
                   #file_info{inode = Inode, major_device = Major,
                              minor_device = Minor}) -> true;
same_file_identity(_, _) -> false.

effective_uid() ->
    Temp = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "aura-effective-uid-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    case file:write_file(Temp, <<>>, [exclusive]) of
        ok ->
            Result = case file:read_file_info(Temp) of
                {ok, #file_info{uid = Uid}} -> Uid;
                {error, _} -> -1
            end,
            _ = file:delete(Temp),
            Result;
        {error, _} -> -1
    end.
