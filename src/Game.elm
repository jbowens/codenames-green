module Game exposing (GameData, Model, Msg(..), Player, init, maybeMakeGame, sideOf, update, viewBoard, viewEventLog, viewKeycard, viewStatus)

import Array exposing (Array)
import Cell exposing (Cell)
import Color exposing (Color)
import Dict
import Html exposing (Html, div, h3, span, text)
import Html.Attributes as Attr
import Html.Events exposing (onClick)
import Http
import Json.Decode as Dec
import Json.Encode as Enc
import Side exposing (Side)


init : String -> GameData -> String -> Model
init id data playerId =
    let
        model =
            List.foldl applyEvent
                { id = id
                , seed = data.seed
                , players = Dict.empty
                , events = []
                , cells =
                    List.map3 (\w l1 l2 -> ( w, ( False, l1 ), ( False, l2 ) ))
                        data.words
                        data.oneLayout
                        data.twoLayout
                        |> List.indexedMap (\i ( w, ( e1, l1 ), ( e2, l2 ) ) -> Cell i w ( e1, l1 ) ( e2, l2 ))
                        |> Array.fromList
                , player = { id = playerId, side = Side.None }
                }
                data.events

        player =
            { id = playerId, side = sideOf model playerId }
    in
    { model | player = player }



------ MODEL ------


type alias Model =
    { id : String
    , seed : Int
    , players : Dict.Dict String Side
    , events : List Event
    , cells : Array Cell
    , player : Player
    }


type alias GameData =
    { seed : Int
    , words : List String
    , events : List Event
    , oneLayout : List Color
    , twoLayout : List Color
    }


type alias Update =
    { seed : Int
    , events : List Event
    }


type alias Event =
    { number : Int
    , typ : String
    , playerId : String
    , side : Side
    , index : Int
    }


type alias Player =
    { id : String
    , side : Side
    }


lastEvent : Model -> Int
lastEvent m =
    m.events
        |> List.head
        |> Maybe.map (\x -> x.number)
        |> Maybe.withDefault 0


remainingGreen : Array Cell -> Int
remainingGreen cells =
    15
        - (cells
            |> Array.map Cell.display
            |> Array.filter (\x -> x == Cell.ExposedGreen)
            |> Array.length
          )


exposedBlack : List Cell -> Bool
exposedBlack cells =
    cells
        |> List.map Cell.display
        |> List.any (\x -> x == Cell.ExposedBlack)


sideOf : Model -> String -> Side
sideOf model playerId =
    model.players
        |> Dict.get playerId
        |> Maybe.withDefault Side.None



------ UPDATE ------


type Msg
    = GameUpdate (Result Http.Error Update)
    | WordPicked Cell


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GameUpdate (Ok up) ->
            if up.seed == model.seed then
                ( List.foldl applyEvent model up.events, Cmd.none )

            else
                -- TODO: propagate the fact that the game is over
                ( model, Cmd.none )

        GameUpdate (Err err) ->
            ( model, Cmd.none )

        WordPicked cell ->
            ( model
            , if model.player.side /= Side.None && not (Cell.isExposed (Side.opposite model.player.side) cell) then
                submitGuess model.id model.player cell (lastEvent model)

              else
                Cmd.none
            )


applyEvent : Event -> Model -> Model
applyEvent e model =
    case e.typ of
        "new_player" ->
            { model | players = Dict.update e.playerId (\_ -> Just e.side) model.players, events = e :: model.events }

        "player_left" ->
            { model | players = Dict.update e.playerId (\_ -> Nothing) model.players, events = e :: model.events }

        "set_team" ->
            { model | players = Dict.update e.playerId (\_ -> Just e.side) model.players, events = e :: model.events }

        "guess" ->
            case Array.get e.index model.cells of
                Just cell ->
                    { model
                        | cells = Array.set e.index (Cell.tapped e.side cell) model.cells
                        , events = e :: model.events
                    }

                Nothing ->
                    { model | events = e :: model.events }

        _ ->
            { model | events = e :: model.events }



------ NETWORK ------


maybeMakeGame : String -> (Result Http.Error GameData -> a) -> Cmd a
maybeMakeGame id msg =
    Http.post
        { url = "http://localhost:8080/new-game"
        , body = Http.jsonBody (Enc.object [ ( "game_id", Enc.string id ) ])
        , expect = Http.expectJson msg decodeGameData
        }


submitGuess : String -> Player -> Cell -> Int -> Cmd Msg
submitGuess gameId player cell lastEventId =
    Http.post
        { url = "http://localhost:8080/guess"
        , body =
            Http.jsonBody
                (Enc.object
                    [ ( "game_id", Enc.string gameId )
                    , ( "index", Enc.int cell.index )
                    , ( "player_id", Enc.string player.id )
                    , ( "team", Side.encode player.side )
                    , ( "last_event", Enc.int lastEventId )
                    ]
                )
        , expect = Http.expectJson GameUpdate decodeUpdate
        }


decodeGameData : Dec.Decoder GameData
decodeGameData =
    Dec.map5 GameData
        (Dec.field "state" (Dec.field "seed" Dec.int))
        (Dec.field "words" (Dec.list Dec.string))
        (Dec.field "state" (Dec.field "events" (Dec.list decodeEvent)))
        (Dec.field "one_layout" (Dec.list Color.decode))
        (Dec.field "two_layout" (Dec.list Color.decode))


decodeUpdate : Dec.Decoder Update
decodeUpdate =
    Dec.map2 Update
        (Dec.field "seed" Dec.int)
        (Dec.field "events" (Dec.list decodeEvent))


decodeEvent : Dec.Decoder Event
decodeEvent =
    Dec.map5 Event
        (Dec.field "number" Dec.int)
        (Dec.field "type" Dec.string)
        (Dec.field "player_id" Dec.string)
        (Dec.field "team" Side.decode)
        (Dec.field "index" Dec.int)



------ VIEW ------


viewStatus : Model -> Html a
viewStatus g =
    let
        greens =
            remainingGreen g.cells
    in
    if exposedBlack (Array.toList g.cells) then
        -- handle time tokens
        div [ Attr.id "status", Attr.class "lost" ]
            [ text "You lost :(" ]

    else if greens == 0 then
        div [ Attr.id "status", Attr.class "won" ]
            [ text "You won!" ]

    else
        div [ Attr.id "status", Attr.class "in-progress" ]
            [ text (String.fromInt greens), text " agents remaining" ]


viewBoard : Model -> Html Msg
viewBoard model =
    div [ Attr.id "board" ]
        (List.map
            (\c -> viewCell c model.player.side)
            (Array.toList model.cells)
        )


viewCell : Cell -> Side -> Html Msg
viewCell cell side =
    let
        green =
            cell.a == ( True, Color.Green ) || cell.b == ( True, Color.Green )

        black =
            cell.a == ( True, Color.Black ) || cell.b == ( True, Color.Black )

        pickable =
            side /= Side.None && not green && not black && not (Cell.isExposed side cell)
    in
    div
        [ Attr.classList
            [ ( "cell", True )
            , ( "green", green )
            , ( "black", black )
            , ( "pickable", pickable )
            ]
        , onClick (WordPicked cell)
        ]
        [ text cell.word ]


viewEventLog : Model -> Html Msg
viewEventLog model =
    div [ Attr.id "event-log" ]
        [ h3 [] [ text "Activity log" ]
        , div [ Attr.class "events" ]
            (model.events
                |> List.concatMap (viewEvent model)
            )
        ]


viewEvent : Model -> Event -> List (Html Msg)
viewEvent model e =
    case e.typ of
        "new_player" ->
            [ div [] [ text "A new player has joined the game." ] ]

        "player_left" ->
            [ div [] [ text "A player has left the game." ] ]

        "guess" ->
            Array.get e.index model.cells
                |> Maybe.map
                    (\c ->
                        [ div []
                            [ text "Side "
                            , text (Side.toString e.side)
                            , text " tapped "
                            , span [] [ text c.word ]
                            ]
                        ]
                    )
                |> Maybe.withDefault []

        _ ->
            []


viewKeycard : Model -> Side -> Html a
viewKeycard model side =
    div [ Attr.id "key-card" ]
        (model.cells
            |> Array.toList
            |> List.map (Cell.sideColor side)
            |> List.map
                (\c ->
                    div
                        [ Attr.class "cell"
                        , Attr.class (Color.toString c)
                        ]
                        []
                )
        )
