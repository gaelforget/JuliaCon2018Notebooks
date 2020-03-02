using CSV, DataFrames, Statistics
using FortranFiles, MeshArrays, MITgcmTools

##

function get_from_dataverse(nam::String,pth::String)
    tmp = CSV.File("nctiles_climatology.csv") |> DataFrame!
    ii = findall([occursin("$nam", tmp[i,:name]) for i=1:size(tmp,1)])
    !isdir("$pth"*"$nam") ? mkdir("$pth"*"$nam") : nothing
    for i in ii
        ID=tmp[i,:ID]
        nam1=tmp[i,:name]
        nam2=joinpath("$pth"*"$nam/",nam1)
        run(`wget --content-disposition https://dataverse.harvard.edu/api/access/datafile/$ID`);
        run(`mv $nam1 $nam2`);
    end
end

function get_grid_if_needed()
    if !isdir("../inputs/GRID_LLC90")
        run(`git clone https://github.com/gaelforget/GRID_LLC90 ../inputs/GRID_LLC90`)
    end
end

function get_velocity_if_needed()
    pth="../inputs/nctiles_climatology/"
    !isdir("$pth") ? mkdir("$pth") : nothing
    !isdir("$pth"*"UVELMASS") ? get_from_dataverse("UVELMASS",pth) : nothing
    !isdir("$pth"*"VVELMASS") ? get_from_dataverse("VVELMASS",pth) : nothing
end

function read_velocities(mygrid::gcmgrid,t::Int)
    pth="../inputs/nctiles_climatology/"
    u=Main.read_nctiles("$pth"*"UVELMASS/UVELMASS","UVELMASS",mygrid,I=(:,:,:,t))
    v=Main.read_nctiles("$pth"*"VVELMASS/VVELMASS","VVELMASS",mygrid,I=(:,:,:,t))
    return u,v
end

#Convert Velocity (m/s) to transport (m^3/s)
function convert_velocities(U,V,γ)
    for i in eachindex(U)
        tmp1=U[i]; tmp1[(!isfinite).(tmp1)] .= 0.0
        tmp1=V[i]; tmp1[(!isfinite).(tmp1)] .= 0.0
        U[i]=γ["DRF"][i[2]]*U[i].*γ["DYG"][i[1]]
        V[i]=γ["DRF"][i[2]]*V[i].*γ["DXG"][i[1]]
    end
    return U,V
end

##

"""
    trsp_read(myspec::String,mypath::String)

Function that reads files that were generated by `trsp_prep`
"""
function trsp_read(myspec::String,mypath::String)
    mygrid=GridSpec(myspec,mypath)
    TrspX=mygrid.read(mypath*"TrspX.bin",MeshArray(mygrid,Float32))
    TrspY=mygrid.read(mypath*"TrspY.bin",MeshArray(mygrid,Float32))
    TauX=mygrid.read(mypath*"TauX.bin",MeshArray(mygrid,Float32))
    TauY=mygrid.read(mypath*"TauY.bin",MeshArray(mygrid,Float32))
    SSH=mygrid.read(mypath*"SSH.bin",MeshArray(mygrid,Float32))
    return TrspX, TrspY, TauX, TauY, SSH
end

"""
    trsp_prep(mygrid,GridVariables,dirOut)

Function that generates small binary files (2D) from large netcdf ones (4D).

```
using FortranFiles, MeshArrays
!isdir("nctiles_climatology") ? error("missing files") : nothing
include(joinpath(dirname(pathof(MeshArrays)),"gcmfaces_nctiles.jl"))
(TrspX, TrspY, TauX, TauY, SSH)=trsp_prep(mygrid,GridVariables,"GRID_LLC90/");
```
"""
function trsp_prep(mygrid::gcmgrid,GridVariables::Dict,dirOut::String="")

    #wind stress
    fileName="nctiles_climatology/oceTAUX/oceTAUX"
    oceTAUX=read_nctiles(fileName,"oceTAUX",mygrid)
    fileName="nctiles_climatology/oceTAUY/oceTAUY"
    oceTAUY=read_nctiles(fileName,"oceTAUY",mygrid)
    oceTAUX=mask(oceTAUX,0.0)
    oceTAUY=mask(oceTAUY,0.0)

    #sea surface height anomaly
    fileName="nctiles_climatology/ETAN/ETAN"
    ETAN=read_nctiles(fileName,"ETAN",mygrid)
    fileName="nctiles_climatology/sIceLoad/sIceLoad"
    sIceLoad=read_nctiles(fileName,"sIceLoad",mygrid)
    rhoconst=1029.0
    myssh=(ETAN+sIceLoad./rhoconst)
    myssh=mask(myssh,0.0)

    #seawater transports
    fileName="nctiles_climatology/UVELMASS/UVELMASS"
    U=read_nctiles(fileName,"UVELMASS",mygrid)
    fileName="nctiles_climatology/VVELMASS/VVELMASS"
    V=read_nctiles(fileName,"VVELMASS",mygrid)
    U=mask(U,0.0)
    V=mask(V,0.0)

    #time averaging and vertical integration
    TrspX=similar(GridVariables["DXC"])
    TrspY=similar(GridVariables["DYC"])
    TauX=similar(GridVariables["DXC"])
    TauY=similar(GridVariables["DYC"])
    SSH=similar(GridVariables["XC"])

    for i=1:mygrid.nFaces
        tmpX=mean(U.f[i],dims=4)
        tmpY=mean(V.f[i],dims=4)
        for k=1:length(GridVariables["RC"])
            tmpX[:,:,k]=tmpX[:,:,k].*GridVariables["DYG"].f[i]
            tmpX[:,:,k]=tmpX[:,:,k].*GridVariables["DRF"][k]
            tmpY[:,:,k]=tmpY[:,:,k].*GridVariables["DXG"].f[i]
            tmpY[:,:,k]=tmpY[:,:,k].*GridVariables["DRF"][k]
        end
        TrspX.f[i]=dropdims(sum(tmpX,dims=3),dims=(3,4))
        TrspY.f[i]=dropdims(sum(tmpY,dims=3),dims=(3,4))
        TauX.f[i]=dropdims(mean(oceTAUX.f[i],dims=3),dims=3)
        TauY.f[i]=dropdims(mean(oceTAUY.f[i],dims=3),dims=3)
        SSH.f[i]=dropdims(mean(myssh.f[i],dims=3),dims=3)
    end

    if !isempty(dirOut)
        write_bin(TrspX,dirOut*"TrspX.bin")
        write_bin(TrspY,dirOut*"TrspY.bin")
        write_bin(TauX,dirOut*"TauX.bin")
        write_bin(TauY,dirOut*"TauY.bin")
        write_bin(SSH,dirOut*"SSH.bin")
    end

    return TrspX, TrspY, TauX, TauY, SSH
end

"""
    trsp_prep(mygrid,GridVariables,dirOut)

Function that writes a `MeshArray` to a binary file using `FortranFiles`.
"""
function write_bin(inFLD::MeshArray,filOut::String)
    recl=prod(inFLD.grid.ioSize)*4
    tmp=Float32.(convert2gcmfaces(inFLD))
    println("saving to file: "*filOut)
    f =  FortranFile(filOut,"w",access="direct",recl=recl,convert="big-endian")
    write(f,rec=1,tmp)
    close(f)
end

##

"""
    rotate_uv(uv,γ)

    1. Convert to `Sv` units and mask out land
    2. Interpolate `x/y` transport to grid cell center
    3. Convert to `Eastward/Northward` transport
    4. Display Subdomain Arrays (optional)
"""
function rotate_uv(uv,γ)
    u=1e-6 .*uv["U"]; v=1e-6 .*uv["V"];
    u[findall(γ["hFacW"][:,1].==0)].=NaN
    v[findall(γ["hFacS"][:,1].==0)].=NaN;

    nanmean(x) = mean(filter(!isnan,x))
    nanmean(x,y) = mapslices(nanmean,x,dims=y)
    (u,v)=exch_UV(u,v); uC=similar(u); vC=similar(v)
    for iF=1:u.grid.nFaces
        tmp1=u[iF][1:end-1,:]; tmp2=u[iF][2:end,:]
        uC[iF]=reshape(nanmean([tmp1[:] tmp2[:]],2),size(tmp1))
        tmp1=v[iF][:,1:end-1]; tmp2=v[iF][:,2:end]
        vC[iF]=reshape(nanmean([tmp1[:] tmp2[:]],2),size(tmp1))
    end

    cs=γ["AngleCS"]
    sn=γ["AngleSN"]
    u=uC.*cs-vC.*sn
    v=uC.*sn+vC.*cs;

    return u,v,uC,vC
end

"""
    interp_uv(u,v)
"""
function interp_uv(u,v)
    mypath="../inputs/GRID_LLC90/"
    SPM,lon,lat=read_SPM(mypath) #interpolation matrix (sparse)
    uI=MatrixInterp(write(u),SPM,size(lon)) #interpolation itself
    vI=MatrixInterp(write(v),SPM,size(lon)); #interpolation itself
    return transpose(uI),transpose(vI),vec(lon[:,1]),vec(lat[1,:])
end

"""
    read_llc90_grid()
"""
function read_llc90_grid()
    mypath="../inputs/GRID_LLC90/"
    mygrid=GridSpec("LatLonCap",mypath)
    γ=GridLoad(mygrid)
end


"""
    initialize_locations()

Define `uInitS` as an array of initial conditions
"""
function initialize_locations(XC)
    uInitS = Array{Float64,2}(undef, 3, prod(XC.grid.ioSize))

    kk = 0
    for fIndex = 1:5
        nx, ny = XC.fSize[fIndex]
        ii1 = 0.5:1.0:nx
        ii2 = 0.5:1.0:ny
        n1 = length(ii1)
        n2 = length(ii2)
        for i1 in eachindex(ii1)
            for i2 in eachindex(ii2)
                if msk[fIndex][Int(round(i1+0.5)),Int(round(i2+0.5))]
                    kk += 1
                    let kk = kk
                        uInitS[1, kk] = ii1[i1]
                        uInitS[2, kk] = ii2[i2]
                        uInitS[3, kk] = fIndex
                    end
                end
            end
        end
    end

    uInitS=uInitS[:,1:kk]
    du=fill(0.0,size(uInitS));

    return uInitS,du
end

"""
    postprocess_locations()

Copy `sol` to a `DataFrame` & map position to lon,lat coordinates
"""
function postprocess_locations(sol)
    ID=collect(1:size(sol,2))*ones(1,size(sol,3))
    x=sol[1,:,:]
    y=sol[2,:,:]
    fIndex=sol[3,:,:]
    df = DataFrame(ID=Int.(ID[:]), x=x[:], y=y[:], fIndex=fIndex[:])

    lon=Array{Float64,1}(undef,size(df,1)); lat=similar(lon)

    for ii=1:length(lon)
        #get location in grid index space
        x=df[ii,:x]; y=df[ii,:y]; fIndex=Int(df[ii,:fIndex])
        dx,dy=[x - floor(x),y - floor(y)]
        i_c,j_c = Int32.(floor.([x y])) .+ 2
        #interpolate lon and lat to position
        tmp=view(YC[fIndex],i_c:i_c+1,j_c:j_c+1)
        lat[ii]=(1.0-dx)*(1.0-dy)*tmp[1,1]+dx*(1.0-dy)*tmp[2,1]+(1.0-dx)*dy*tmp[1,2]+dx*dy*tmp[2,2]

        tmp=view(XC[fIndex],i_c:i_c+1,j_c:j_c+1)
        if (maximum(tmp)>minimum(tmp)+180)&&(lat[ii]<88)
            tmp1=deepcopy(tmp)
            tmp1[findall(tmp.<maximum(tmp)-180)] .+= 360.
            tmp=tmp1
        end
        #kk=findall(tmp.<maximum(tmp)-180); tmp[kk].=tmp[kk].+360.0
        lon[ii]=(1.0-dx)*(1.0-dy)*tmp[1,1]+dx*(1.0-dy)*tmp[2,1]+(1.0-dx)*dy*tmp[1,2]+dx*dy*tmp[2,2]
    end

    df.lon=lon; df.lat=lat; #show(df[end-3:end,:])
    return df
end
