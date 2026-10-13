import { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fastifyMultipart from "@fastify/multipart";
import { deserializePlayerData, getClientSerializedData } from "../../data/utils";
import { createReadStream } from "fs";
import { getAllPlayersSync, getPlayerSync, replacePlayerDataSync, updatePlayerSync } from "../../data/wdfpData";
import { Player } from "../../data/types";

interface SaveQuery {
    id: string | undefined
}

interface GetPlayersQuery {
    page: string | undefined,
    perPage: string | undefined
}

// fields that can be live-edited through the web UI
const editableNumericFields = [
    "vmoney", "freeVmoney", "freeMana", "paidMana", "starCrumb",
    "bondToken", "rankPoint", "stamina", "boostPoint", "bossBoostPoint", "expPool"
] as const
const editableStringFields = ["name", "comment"] as const
type EditableNumericField = typeof editableNumericFields[number]
type EditableField = EditableNumericField | typeof editableStringFields[number]

const liveEditState = (player: Player) => ({
    name: player.name,
    comment: player.comment,
    vmoney: player.vmoney,
    freeVmoney: player.freeVmoney,
    freeMana: player.freeMana,
    paidMana: player.paidMana,
    starCrumb: player.starCrumb,
    bondToken: player.bondToken,
    rankPoint: player.rankPoint,
    stamina: player.stamina,
    boostPoint: player.boostPoint,
    bossBoostPoint: player.bossBoostPoint,
    expPool: player.expPool
})

const defaultPerPage = 25

const routes = async (fastify: FastifyInstance) => {
    fastify.get("/", async (request: FastifyRequest, reply: FastifyReply) => {
        // get page and perPage
        const { page, perPage } = request.query as GetPlayersQuery
        const parsedPage = page === undefined ? 0 : Number.parseInt(page)
        const parsedPerPage = perPage === undefined ? defaultPerPage : Number.parseInt(perPage)
        if (isNaN(parsedPage) || isNaN(parsedPerPage)) return reply.status(400).send({
            "error": "Bad Request",
            "message": "Invalid query parameters."
        })

        // get players
        const players = getAllPlayersSync(parsedPage * parsedPerPage, Math.min(defaultPerPage, parsedPerPage))

        return reply.status(200).send(players)
    })

    fastify.get("/save", async (request: FastifyRequest, reply: FastifyReply) => {
        // get id
        const { id } = request.query as SaveQuery
        const playerId = Number(id)
        if (isNaN(playerId)) return reply.redirect("/player");

        // get player
        const data = getClientSerializedData(playerId, { serializeRushEventData: true })
        if (data === null) return reply.redirect("/player");

        // otherwise, send
        reply.header("content-disposition", "attachment; save.json")
        reply.type('application/json').send(data)
    })

    fastify.get("/state", async (request: FastifyRequest, reply: FastifyReply) => {
        // get id
        const { id } = request.query as SaveQuery
        const playerId = Number(id)
        if (isNaN(playerId)) return reply.status(400).send({
            "error": "Bad Request",
            "message": "Invalid player id."
        })

        const player = getPlayerSync(playerId)
        if (player === null) return reply.status(404).send({
            "error": "Not Found",
            "message": "Player not found."
        })

        return reply.status(200).send(liveEditState(player))
    })

    fastify.post("/edit", async (request: FastifyRequest, reply: FastifyReply) => {
        // get id
        const { id } = request.query as SaveQuery
        const playerId = Number(id)
        if (isNaN(playerId)) return reply.status(400).send({
            "error": "Bad Request",
            "message": "Invalid player id."
        })

        const player = getPlayerSync(playerId)
        if (player === null) return reply.status(404).send({
            "error": "Not Found",
            "message": "Player not found."
        })

        const body = request.body
        if (body === undefined || typeof body !== "object") return reply.status(400).send({
            "error": "Bad Request",
            "message": "Invalid request body."
        })

        // build the update from the editable field whitelist
        const changes: Partial<Player> = {}
        const entries = body as Record<string, unknown>
        for (const key of Object.keys(entries)) {
            const value = entries[key]
            if ((editableNumericFields as readonly string[]).includes(key)) {
                const parsed = value as number
                if (typeof parsed !== "number" || !Number.isSafeInteger(parsed) || 0 > parsed) {
                    return reply.status(400).send({
                        "error": "Bad Request",
                        "message": `Field "${key}" must be a non-negative integer.`
                    })
                }
                changes[key as EditableNumericField] = parsed
            } else if ((editableStringFields as readonly string[]).includes(key)) {
                const parsed = value as string
                if (typeof parsed !== "string" || 100 < parsed.length) {
                    return reply.status(400).send({
                        "error": "Bad Request",
                        "message": `Field "${key}" must be a string of at most 100 characters.`
                    })
                }
                changes[key as typeof editableStringFields[number]] = parsed
            }
        }

        if (Object.keys(changes).length === 0) return reply.status(400).send({
            "error": "Bad Request",
            "message": "No editable fields were provided."
        })

        updatePlayerSync({ id: playerId, ...changes })

        return reply.status(200).send(liveEditState(getPlayerSync(playerId)!))
    })

    fastify.post("/save", async (request: FastifyRequest, reply: FastifyReply) => {
        // get id
        const { id } = request.query as SaveQuery
        const playerId = Number(id)
        if (isNaN(playerId)) return reply.redirect("/player");
        
        try {
            // get file
            const file = await request.file()
            if (file === undefined) return reply.redirect(`/player/${id}`);

            const text = (await file.toBuffer()).toString('utf-8')
            const json = JSON.parse(text)

            const saveData = json['data'] === undefined ? json : json['data']
            
            const parsedData = deserializePlayerData(playerId, saveData)

            replacePlayerDataSync(parsedData)

        } catch (error) {
            return reply.redirect(`/player/${id}?error=${error}`);
        }

        return reply.redirect(`/player/${id}`);
    })
}

export default routes;