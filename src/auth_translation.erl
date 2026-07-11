-module(auth_translation).

-export([verify_client_cert/2, generate_livekit_token/3]).

verify_client_cert(ClientCertDN, ClientCertSAN) ->
    case parse_dn(ClientCertDN) of
        {ok, CN} ->
            Role = extract_role_from_san(ClientCertSAN),
            RoomId = <<"court-room-room123">>,
            {ok, CN, RoomId, Role};
        error ->
            {error, unauthorized}
    end.

generate_livekit_token(ApiKey, ApiSecret, ParticipantIdentity) ->
    Header = #{<<"alg">> => <<"HS256">>, <<"typ">> => <<"JWT">>},
    Claims = #{
        <<"exp">> => erlang:system_time(second) + 7200,
        <<"iss">> => ApiKey,
        <<"sub">> => ParticipantIdentity,
        <<"video">> => #{
            <<"room">> => <<"court-room-room123">>,
            <<"roomJoin">> => true,
            <<"canPublish">> => true,
            <<"canSubscribe">> => true,
            <<"roomRecord">> => false
        }
    },
    JWK = jose_jwk:from_oct(ApiSecret),
    JWT = jose_jwt:sign(JWK, Header, Claims),
    {_, CompactToken} = jose_jwt:compact(JWT),
    CompactToken.

parse_dn(DNString) ->
    case re:run(DNString, "CN=([^,]+)", [{capture, [1], binary}]) of
        {match, [CN]} -> {ok, CN};
        nomatch -> error
    end.

extract_role_from_san(SANString) ->
    case re:run(SANString, "role:([^,]+)", [{capture, [1], binary}]) of
        {match, [Role]} -> Role;
        nomatch -> <<"participant">>
    end.
