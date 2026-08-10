async def test_sign_respects_forwarded_proto(client, db_session, settings) -> None:
    from tests.conftest import auth_header, login_as

    pair = await login_as(client, "petr@example.com")
    response = await client.post(
        "/v1/feedback/sign",
        headers={**auth_header(pair["access_token"]), "X-Forwarded-Proto": "https"},
        json={"week": "CW33", "items": [{"title": "SOČR", "lane": "klasika"}]},
    )
    assert response.status_code == 200, response.text
    assert response.json()[0]["url_up"].startswith("https://")
